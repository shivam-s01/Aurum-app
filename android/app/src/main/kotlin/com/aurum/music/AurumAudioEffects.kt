package com.aurum.music

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

/**
 * Audio effects for the native engine. Two completely separate mechanisms:
 *
 * 1. PREMIUM SOUND — runs entirely inside the app's own audio pipeline via
 *    [PremiumSoundProcessor] / [PremiumDspCore] (software DSP, no vendor code,
 *    no AudioEffect objects, no dependency on the audio session).
 *
 *    ROOT-CAUSE FIX ("Premium Sound ON -> fine for a while -> audio glitch"):
 *    Premium Sound used to be built from five platform AudioEffects attached to
 *    the player's audio session (Equalizer + LoudnessEnhancer + Virtualizer +
 *    BassBoost + DynamicsProcessing). Those execute inside the device's audio
 *    HAL / mixer thread, get re-initialised by the OS whenever the AudioTrack is
 *    recreated (sample-rate change between tracks, route change, pause/resume),
 *    and the vendor Virtualizer / BassBoost / DynamicsProcessing implementations
 *    are CPU-heavy and unstable over long sessions, especially once the SoC
 *    thermally throttles. A missed mixer deadline = crackle/glitch. No gain
 *    tuning can fix a fault in the effect chain itself, so Premium Sound no
 *    longer uses it at all.
 *
 * 2. MANUAL controls (custom EQ curve, Bass Boost, volume normalization, Volume
 *    Boost 100-200%) keep using the platform Equalizer + LoudnessEnhancer, with a
 *    DynamicsProcessing limiter for safety. They are only attached when one of
 *    them is actually in use, and they are only ever touched when the user
 *    changes a setting — never per song, never on a timer.
 *
 * Neither mechanism does any per-track or periodic live re-tuning any more.
 */
@UnstableApi
class AurumAudioEffects(
    private val player: ExoPlayer,
    private val context: Context,
    private val premiumDsp: PremiumSoundProcessor,
) {

    companion object {
        private const val TAG = "AurumAudioEffects"

        private const val BASS_BOOST_LOUDNESS_GAIN_MB = 400
        private const val BASS_BOOST_SUB_BASS_EXTRA_MB = 400
        private const val BASS_BOOST_BASS_EXTRA_MB = 300

        // Premium Sound intensity ceiling by output route (speaker is the
        // most fatiguing / most likely to distort, wired the cleanest).
        private const val K_S1 = 0.55f // speaker
        private const val K_S2 = 1.0f // wired
        private const val K_S3 = 0.85f // bluetooth
        private const val K_S4 = 0.75f // unknown

        // Battery-saver taper: at/below K_B1 percent (and not charging) the
        // effect is scaled by K_B2.
        private const val K_B1 = 20
        private const val K_B2 = 0.5f

        // Louder system volume -> proportionally less effect (K_A2 at silence,
        // K_A1 at full volume).
        private const val K_A1 = 0.7f
        private const val K_A2 = 1.0f

        // DynamicsProcessing limiter (safety net for manual boosts only).
        private const val K_L1 = -1.5f // threshold dB
        private const val K_L2 = 6.0f // ratio
        private const val K_L3 = 5f // attack ms
        private const val K_L4 = 100f // release ms
        private const val K_L5 = 0f // post gain dB

        // Combined per-band safety ceiling for the manual EQ (Bass Boost bump
        // + user curve), independent of the device's own reported range.
        private const val K_CAP_POS = 600 // +6.0dB
        private const val K_CAP_NEG = -600 // -6.0dB

        // LoudnessEnhancer may only use whatever part of this budget the EQ
        // side hasn't already claimed (stacked gain is what clips).
        private const val K_TOTAL_BUDGET_MB = K_CAP_POS
        private const val K_LOUDNESS_FLOOR_MB = 80

        // Volume Boost (100%-200% slider): up to +9dB of extra electrical gain,
        // with its own ceiling so a maxed EQ can never swallow it.
        private const val K_VOLBOOST_MAX_GAIN_MB = 900
        private const val K_VOLBOOST_TOTAL_CEILING_MB = K_CAP_POS + K_VOLBOOST_MAX_GAIN_MB
        private const val K_VOLBOOST_RAMP_MS = 260L
        private const val K_VOLBOOST_RAMP_STEP_MS = 16L
    }

    // ── Platform effect objects (manual controls only) ───────────────────
    private var equalizer: Equalizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var limiter: DynamicsProcessing? = null
    private var currentSessionId: Int = 0

    // True once the platform effects have actually been constructed for the
    // current session (as opposed to skipped because nothing was wanted).
    private var platformAttached = false

    private var loudnessHealthy = true
    private var equalizerHealthy = true
    private var limiterHealthy = true
    private var limiterSupported = true

    private var lastAppliedLoudnessGain: Int? = null
    private var lastAppliedLimiterEnabled: Boolean? = null
    private var lastAppliedEqEnabled: Boolean? = null
    private var lastAppliedEqGains: List<Int> = emptyList()

    // Peak positive band gain currently on the Equalizer; LoudnessEnhancer's
    // gain budget shrinks by this much (see _loudnessBudgetMb).
    @Volatile private var lastEqPeakGainMb: Int = 0

    // ── User state ───────────────────────────────────────────────────────
    private var lastBassBoost = false
    private var lastVolNorm = false
    private var lastBandGains: List<Int>? = null
    private var lastPremiumSound = false
    private var premiumCompare: Boolean? = null // A/B compare override, null = follow setting
    private var lastKnownSourceKbps: Int? = null

    // Called right before something that needs the PCM path (platform effects
    // or Premium Sound's in-app DSP) is used. AurumAudioEngine uses it to drop
    // audio offload, because offload bypasses every audio processor/effect.
    // Not invoked when nothing is wanted, so users who never touch any of this
    // keep offload (cool + low power). Idempotent on the engine side.
    var onEffectsAboutToAttach: (() -> Unit)? = null

    // ── Volume Boost state ───────────────────────────────────────────────
    @Volatile private var volumeBoostTargetFraction: Float = 0f
    private var volumeBoostFraction: Float = 0f
    private var volumeBoostRampRunnable: Runnable? = null
    private val rampHandler = Handler(Looper.getMainLooper())

    private fun hasCustomCurve(): Boolean = lastBandGains?.any { it != 0 } == true

    // Only the MANUAL controls need platform effects. Premium Sound does not.
    private fun wantsPlatformEffects(): Boolean =
        lastBassBoost || lastVolNorm || hasCustomCurve() || volumeBoostFraction > 0.001f

    private val audioManager: AudioManager? by lazy {
        try { context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager } catch (_: Exception) { null }
    }

    private val sessionIdListener = object : Player.Listener {
        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            if (audioSessionId == currentSessionId) return
            _at1(audioSessionId)
        }
    }

    // Output route changes (headphones in/out, Bluetooth connect) change the
    // per-route intensity ceiling — only a cheap parameter push, nothing is
    // re-attached or re-created.
    private val audioDeviceCallback: android.media.AudioDeviceCallback? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            object : android.media.AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                    if (lastPremiumSound || premiumCompare == true) pushPremium()
                }
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    if (lastPremiumSound || premiumCompare == true) pushPremium()
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

    // ═════════════════════════════════════════════════════════════════════
    // PREMIUM SOUND (in-app DSP)
    // ═════════════════════════════════════════════════════════════════════

    fun applyPremiumSound(enabled: Boolean) {
        lastPremiumSound = enabled
        pushPremium()
    }

    /** A/B compare: force Premium Sound on/off without touching the saved setting. */
    fun setPremiumSoundCompare(enabled: Boolean) {
        premiumCompare = enabled
        pushPremium()
    }

    fun exitPremiumSoundCompare() {
        premiumCompare = null
        pushPremium()
    }

    /** Source bitrate of the CURRENT song (0/null = unknown) for the low-bitrate tilt. */
    fun reportSourceBitrate(kbps: Int?) {
        lastKnownSourceKbps = kbps
        pushPremium()
    }

    private fun pushPremium() {
        val wanted = premiumCompare ?: lastPremiumSound
        if (wanted) {
            // Make sure we're on the PCM path — offload bypasses audio processors.
            try { onEffectsAboutToAttach?.invoke() } catch (_: Exception) {}
        }
        val intensity = if (wanted) _mx1() else 1f
        premiumDsp.setParams(wanted, intensity, lastKnownSourceKbps ?: 0)
    }

    // ── Intensity ceiling (route / battery / system volume) ──────────────

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

    // ═════════════════════════════════════════════════════════════════════
    // MANUAL CONTROLS (platform effects: custom EQ / Bass Boost / Vol Boost)
    // ═════════════════════════════════════════════════════════════════════

    private fun _at1(sessionId: Int) {
        _rl1()
        currentSessionId = sessionId
        platformAttached = false
        loudnessHealthy = true
        equalizerHealthy = true
        limiterHealthy = true
        limiterSupported = true
        lastAppliedLoudnessGain = null
        lastAppliedLimiterEnabled = null
        lastAppliedEqEnabled = null
        lastAppliedEqGains = emptyList()
        lastEqPeakGainMb = 0

        // Nothing manual is wanted -> attach nothing at all, so audio offload
        // stays available (cooler, less battery). See AurumAudioEngine.
        if (!wantsPlatformEffects()) {
            equalizerHealthy = false
            loudnessHealthy = false
            limiterHealthy = false
            limiterSupported = false
            return
        }

        // Something manual is wanted: drop offload BEFORE the effects exist.
        try { onEffectsAboutToAttach?.invoke() } catch (_: Exception) {}
        platformAttached = true

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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                limiter = _lm1(sessionId)
            } catch (e: Exception) {
                Log.w(TAG, "DynamicsProcessing limiter attach failed for session $sessionId: $e")
                limiterHealthy = false
                limiterSupported = false
            }
        } else {
            limiterHealthy = false
            limiterSupported = false
        }

        _syncPlatform()
    }

    private fun _rl1() {
        try { equalizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        try { limiter?.release() } catch (_: Exception) {}
        equalizer = null
        loudnessEnhancer = null
        limiter = null
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.P)
    private fun _lm1(sessionId: Int): DynamicsProcessing {
        val channelCount = 2
        // Only a limiter stage is used, so the light, low-latency TIME_RESOLUTION
        // variant is the right one (the FFT-based FREQUENCY_RESOLUTION variant
        // costs far more CPU and adds latency for no benefit here).
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_TIME_RESOLUTION,
            channelCount,
            false, 0, // no pre-EQ
            false, 0, // no multi-band compressor
            false, 0, // no post-EQ
            true,     // limiter stage
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

        // Effects were skipped at attach time (nothing was wanted then) — now
        // something is, so attach for real on the current session.
        if (!platformAttached && wantsPlatformEffects() && currentSessionId != 0) {
            _at1(currentSessionId)
            return
        }
        _syncPlatform()
    }

    // EQ first (it updates lastEqPeakGainMb), then the limiter, then
    // LoudnessEnhancer (whose budget depends on that peak).
    private fun _syncPlatform() {
        _ap2(lastBassBoost, lastVolNorm, lastBandGains)
        _syncLimiter()
        _applyLoudness()
    }

    private fun _syncLimiter() {
        val hasBoostedBand = lastBandGains?.any { it > 0 } == true
        val wanted = lastBassBoost || hasBoostedBand ||
            volumeBoostFraction > 0.001f || volumeBoostTargetFraction > 0.001f
        if (lastAppliedLimiterEnabled != wanted) {
            _lm2(wanted)
            lastAppliedLimiterEnabled = wanted
        }
    }

    // How much of the shared K_TOTAL_BUDGET_MB LoudnessEnhancer may still use,
    // given what the EQ side already spends. Never exceeds true headroom.
    private fun _loudnessBudgetMb(requestedGainMb: Int): Int {
        if (requestedGainMb <= 0) return 0
        val trueHeadroom = (K_TOTAL_BUDGET_MB - lastEqPeakGainMb).coerceAtLeast(0)
        val preferred = if (trueHeadroom >= K_LOUDNESS_FLOOR_MB) K_LOUDNESS_FLOOR_MB else trueHeadroom
        return minOf(requestedGainMb, preferred, trueHeadroom)
    }

    // The one place LoudnessEnhancer's gain is decided: Bass Boost's lift plus
    // Volume Boost, combined and clamped. Idempotent — writes only on change.
    private fun _applyLoudness() {
        if (!loudnessHealthy) return
        val enhancer = loudnessEnhancer ?: return
        try {
            val bassGain = if (lastBassBoost) _loudnessBudgetMb(BASS_BOOST_LOUDNESS_GAIN_MB) else 0
            val volumeBoostRequested = (K_VOLBOOST_MAX_GAIN_MB * volumeBoostFraction).toInt()
            val combinedRequested = bassGain + volumeBoostRequested
            val targetGain = if (combinedRequested > 0) {
                minOf(combinedRequested, (K_VOLBOOST_TOTAL_CEILING_MB - lastEqPeakGainMb).coerceAtLeast(0))
            } else 0

            if (targetGain > 0) {
                if (lastAppliedLoudnessGain == null) {
                    enhancer.enabled = true
                }
                if (lastAppliedLoudnessGain != targetGain) {
                    try {
                        enhancer.setTargetGain(targetGain)
                        lastAppliedLoudnessGain = targetGain
                    } catch (e: Exception) {
                        // Retry once at half the gain so the user still gets a
                        // working boost instead of a silent no-op.
                        val fallback = (targetGain / 2).coerceAtLeast(0)
                        Log.w(TAG, "LoudnessEnhancer gain ${targetGain}mB rejected ($e) — retrying at ${fallback}mB")
                        try {
                            enhancer.setTargetGain(fallback)
                            lastAppliedLoudnessGain = fallback
                        } catch (e2: Exception) {
                            Log.w(TAG, "LoudnessEnhancer fallback gain also rejected ($e2)")
                        }
                    }
                }
            } else if (lastAppliedLoudnessGain != null) {
                enhancer.enabled = false
                lastAppliedLoudnessGain = null
            }
        } catch (e: Exception) {
            Log.w(TAG, "LoudnessEnhancer apply failed: $e — disabling for this session")
            loudnessHealthy = false
        }
    }

    private fun _ap2(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?) {
        if (!equalizerHealthy) return
        val eq = equalizer ?: return

        try {
            val bandCount = eq.numberOfBands.toInt()
            if (bandCount <= 0) return

            val savedBands = (0 until bandCount).map { i -> bandGainsMb?.getOrNull(i) ?: 0 }
            val hasCustomCurve = savedBands.any { it != 0 }

            if (!hasCustomCurve && !bassBoost) {
                if (lastAppliedEqEnabled != false) {
                    eq.enabled = false
                    lastAppliedEqEnabled = false
                }
                // Equalizer is flat/off: it no longer spends any headroom, and
                // the next enable must rewrite every band.
                lastEqPeakGainMb = 0
                lastAppliedEqGains = emptyList()
                return
            }

            if (lastAppliedEqEnabled != true) {
                eq.enabled = true
                lastAppliedEqEnabled = true
            }

            val range = eq.bandLevelRange
            val minMb = range[0].toInt()
            val maxMb = range[1].toInt()

            var rejectedBands = 0
            var unchangedBands = 0
            val newAppliedGains = IntArray(bandCount)
            for (i in 0 until bandCount) {
                var gain = if (volNorm && !hasCustomCurve) 0 else savedBands[i]

                if (bassBoost) {
                    if (i == 0) gain += BASS_BOOST_SUB_BASS_EXTRA_MB
                    if (i == 1) gain += BASS_BOOST_BASS_EXTRA_MB
                }

                // Combined ceiling first, then the device's own range.
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
            lastEqPeakGainMb = newAppliedGains.maxOrNull()?.coerceAtLeast(0) ?: 0

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

    // ── Volume Boost (100%-200% slider) ──────────────────────────────────

    /// [percent] is 100-200 (100 = off). Only ever adds gain.
    fun setVolumeBoost(percent: Int) {
        val clamped = percent.coerceIn(100, 200)
        val fraction = (clamped - 100) / 100f
        val wasOff = volumeBoostTargetFraction <= 0.001f
        volumeBoostTargetFraction = fraction

        // Boost turning on for the first time on a session where nothing manual
        // was wanted (so no effects exist yet): attach now. The current fraction
        // is advanced first so _at1's wantsPlatformEffects() sees boost as
        // active; the ramp below then animates from there.
        if (wasOff && fraction > 0.001f && !platformAttached && currentSessionId != 0) {
            volumeBoostFraction = fraction
            _at1(currentSessionId)
        }

        _startVolumeBoostRamp()
    }

    fun currentVolumeBoostPercent(): Int =
        100 + (volumeBoostTargetFraction * 100).toInt()

    // Glides volumeBoostFraction -> target over K_VOLBOOST_RAMP_MS: a sudden
    // LoudnessEnhancer gain step is audible as a thud.
    private fun _startVolumeBoostRamp() {
        _syncLimiter() // arm the limiter BEFORE any gain is added

        volumeBoostRampRunnable?.let { rampHandler.removeCallbacks(it) }
        val stepMs = K_VOLBOOST_RAMP_STEP_MS
        val totalSteps = (K_VOLBOOST_RAMP_MS / stepMs).coerceAtLeast(1)
        var stepsDone = 0
        val startFraction = volumeBoostFraction

        val runnable = object : Runnable {
            override fun run() {
                stepsDone++
                val t = (stepsDone.toFloat() / totalSteps.toFloat()).coerceIn(0f, 1f)
                volumeBoostFraction = startFraction + (volumeBoostTargetFraction - startFraction) * t
                _applyLoudness()
                if (stepsDone < totalSteps) {
                    rampHandler.postDelayed(this, stepMs)
                } else {
                    _syncLimiter() // boost fully off -> limiter may disarm
                }
            }
        }
        volumeBoostRampRunnable = runnable
        rampHandler.post(runnable)
    }

    // ── Introspection ────────────────────────────────────────────────────

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

    // Premium Sound's widening / bass / limiter are all in-app DSP now, so
    // they are supported on every device — the "partial support" notice in the
    // settings screen never needs to show.
    fun describeCapabilities(): Map<String, Any> = mapOf(
        "virtualizerSupported" to true,
        "bassBoostSupported" to true,
        "limiterActive" to true,
        "outputRoute" to _ro1().name,
    )

    fun dispose() {
        volumeBoostRampRunnable?.let { rampHandler.removeCallbacks(it) }
        player.removeListener(sessionIdListener)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager?.unregisterAudioDeviceCallback(audioDeviceCallback)
            }
        } catch (_: Exception) {}
        premiumDsp.setParams(false, 1f, 0)
        _rl1()
    }
}
