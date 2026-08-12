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

        // Crisp/detailed curve — Apple Music-style tonal target: tight
        // controlled low end (not boomy), a light mud-scoop in the low-mids
        // to keep vocals/instruments from sounding thick, forward-but-not-
        // shouty mids for clarity, and extended-but-controlled highs for
        // detail/air without sibilance or harshness. Values in mB, one per
        // band across the device's 10-band-equivalent spread (see
        // premiumGainFor's interpolation — this list is sampled
        // proportionally regardless of the device's actual band count).
        private val K_P4 = listOf(
            15, 5, -35, 15, 45, 55, 45, 30, 5, -10,
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

        // TRIPLE-STACK CRACKLE FIX: LoudnessEnhancer sits ahead of the
        // Equalizer/limiter chain (no pre-EQ stage on the DynamicsProcessing
        // config — see _lm1) and was previously driven straight to
        // BASS_BOOST_LOUDNESS_GAIN_MB (+4dB) with zero awareness of how much
        // headroom the EQ side was already spending via K_CAP_POS. With Bass
        // Boost + Premium Sound + a custom curve all active at once, the EQ
        // bands could already be sitting at the full +6dB ceiling — stacking
        // LoudnessEnhancer's uncapped +4dB on top of that pushed the signal
        // into the limiter's threshold (K_L1) hard and often, and a 6:1
        // ratio limiter slamming repeatedly at a 5ms attack is exactly what
        // reads as crackle/glitch rather than clean compression.
        //
        // Fix: give LoudnessEnhancer its own share of a combined budget
        // instead of applying its gain independently of the EQ side. The
        // total "perceived boost" budget across LoudnessEnhancer + EQ combined
        // gain is capped at K_TOTAL_BUDGET_MB, and LoudnessEnhancer's slice
        // shrinks automatically as EQ-side gain grows — so three sources
        // active together still land under the same effective ceiling as one
        // source alone, instead of stacking additively past it.
        // Total combined ceiling for LoudnessEnhancer + EQ-side gain together
        // — deliberately the SAME value as K_CAP_POS (the EQ side's own
        // combined boost ceiling), so LoudnessEnhancer is only ever allowed
        // to use whatever headroom the EQ side hasn't already claimed.
        private const val K_TOTAL_BUDGET_MB = K_CAP_POS

        // Minimum LoudnessEnhancer gain applied when it's active AND there
        // is at least this much genuine headroom left under K_TOTAL_BUDGET_MB.
        // This is NOT added on top of the budget — it's the smallest slice
        // _loudnessBudgetMb will hand out; if remaining headroom is below
        // this, LoudnessEnhancer gets exactly the remaining headroom instead
        // (which can be 0), never more. This keeps the hard guarantee that
        // LoudnessEnhancer + EQ peak gain can never exceed K_TOTAL_BUDGET_MB
        // (== K_CAP_POS), in every scenario including EQ maxed out.
        private const val K_LOUDNESS_FLOOR_MB = 80
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

    // HEATING/BATTERY FIX: whether the user currently wants ANY of these
    // effects active (custom EQ curve, bass boost, volume normalization,
    // or Premium Sound). Constructing an android.media.audiofx.AudioEffect
    // (Equalizer/LoudnessEnhancer/Virtualizer/BassBoost/DynamicsProcessing)
    // on a session — even with .enabled left false — permanently disables
    // ExoPlayer/Media3's audio offload path for that session. Offload is
    // what lets the DSP/audio HAL do decoding instead of the main CPU, and
    // is one of the single biggest levers for how hot a phone runs and how
    // much battery a music app burns during long playback. Previously
    // _at1() attached all four effect objects unconditionally on every
    // song for every user, whether or not they'd ever touched the
    // equalizer — silently blocking offload for 100% of users, 100% of
    // the time, and keeping the CPU at a higher power state for the
    // entire duration of every song instead of just while the screen is
    // on. This flag lets _at1() skip attachment entirely when nothing is
    // actually wanted, so the common case (no EQ/bass boost/Premium Sound
    // touched) gets real offload and runs cool; effects still attach
    // immediately, same as before, the moment the user turns one on.
    private fun wantsAnyEffect(): Boolean {
        val hasCustomCurve = lastBandGains?.any { it != 0 } == true
        return lastBassBoost || lastVolNorm || lastPremiumSound || hasCustomCurve
    }

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
        // Explicit reset for the new session — belt-and-suspenders on top
        // of _ap2 refreshing this on its next apply. Without this, a stale
        // peak from the previous (now-released) session's Equalizer could
        // theoretically cause LoudnessEnhancer's very first gain
        // computation on the new session to under- or over-budget for one
        // apply cycle before _ap2 catches up.
        lastEqPeakGainMb = 0

        // See wantsAnyEffect() — skip attaching any platform AudioEffect
        // at all when the user hasn't asked for EQ/bass boost/volume
        // normalization/Premium Sound, so offload stays available and
        // playback runs on the low-power DSP path instead of the CPU.
        if (!wantsAnyEffect()) {
            equalizerHealthy = false
            loudnessHealthy = false
            virtualizerHealthy = false
            virtualizerSupported = false
            nativeBassBoostHealthy = false
            nativeBassBoostSupported = false
            limiterHealthy = false
            limiterSupported = false
            currentFadeFraction = 0f
            return
        }

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
        val wasAttached = equalizer != null || nativeBassBoost != null
        lastBassBoost = bassBoost
        lastVolNorm = volNorm
        lastBandGains = bandGainsMb

        // Effects were skipped at attach time (nothing was wanted then) —
        // now something is, so attach for real on the current session
        // before applying. See wantsAnyEffect() / the skip in _at1().
        if (!wasAttached && wantsAnyEffect() && currentSessionId != 0) {
            _at1(currentSessionId)
            return
        }

        // EQ bands applied first so lastEqPeakGainMb is fresh before _ap1
        // computes LoudnessEnhancer's share of the shared budget — same
        // ordering fix as in _ap3, see its comment for why order matters.
        _ap2(bassBoost = bassBoost, volNorm = volNorm, bandGainsMb = bandGainsMb, intensityFraction = currentFadeFraction)
        _ap1(bassBoost)
    }

    fun applyPremiumSound(enabled: Boolean, forceReapply: Boolean = false) {
        if (enabled == lastPremiumSound && !forceReapply) return
        val wasAttached = equalizer != null || nativeBassBoost != null
        lastPremiumSound = enabled

        if (!wasAttached && wantsAnyEffect() && currentSessionId != 0) {
            _at1(currentSessionId)
            return
        }

        _fd2(if (enabled) 1f else 0f)
    }

    fun setPremiumSoundCompare(enabled: Boolean) {
        _fd1()
        currentFadeFraction = if (enabled) 1f else 0f
        _ap3(currentFadeFraction)
    }

    fun reportSourceBitrate(kbps: Int?) {
        lastKnownSourceKbps = kbps
        // Recompute the same effectiveFraction _ap3 would use (raw fade
        // fraction scaled by the device/battery/volume ceiling from _mx1) —
        // using currentFadeFraction directly here would skip that ceiling
        // and let LoudnessEnhancer/EQ run hotter than _ap3 ever allows.
        val ceiling = if (currentFadeFraction > 0f) _mx1() else 0f
        val effectiveFraction = (currentFadeFraction * ceiling).coerceIn(0f, 1f)
        val active = effectiveFraction > 0.001f

        // Re-apply EQ (bitrate compensation gain changes) THEN LoudnessEnhancer,
        // same ordering as applySettings/_ap3 — otherwise a bitrate change
        // arriving mid-playback (detected after the stream starts) updates
        // lastEqPeakGainMb but leaves LoudnessEnhancer's gain stale against
        // the old budget until the next unrelated settings change.
        _ap2(bassBoost = lastBassBoost, volNorm = lastVolNorm, bandGainsMb = lastBandGains, intensityFraction = effectiveFraction)
        if (lastPremiumSound) {
            _applyLoudnessForPremium(effectiveFraction, active)
        } else {
            _ap1(lastBassBoost)
        }
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

    // Peak absolute band gain currently sitting on the Equalizer, updated
    // every time _ap2 applies bands. Used by _loudnessBudgetMb() so
    // LoudnessEnhancer's gain can shrink in lockstep with how much the EQ
    // side is already using — see K_TOTAL_BUDGET_MB above for why this
    // exists (triple-stack crackle fix).
    @Volatile private var lastEqPeakGainMb: Int = 0

    // Computes how much of the shared K_TOTAL_BUDGET_MB LoudnessEnhancer is
    // still allowed to use, given what the EQ side (Bass Boost bump +
    // Premium Sound curve + bitrate compensation, all already combined and
    // capped by K_CAP_POS in _ap2) is currently spending.
    //
    // HARD GUARANTEE: the return value never exceeds
    // (K_TOTAL_BUDGET_MB - lastEqPeakGainMb).coerceAtLeast(0) — i.e. real
    // remaining headroom, full stop. K_LOUDNESS_FLOOR_MB is only ever used
    // to raise the result when there is at least that much genuine headroom
    // available (a soft preference for a minimum audible lift), never to
    // push the result above what's actually left. This is what makes the
    // combined LoudnessEnhancer + EQ total mathematically capped at
    // K_TOTAL_BUDGET_MB in every case, including EQ already maxed out.
    private fun _loudnessBudgetMb(requestedGainMb: Int): Int {
        if (requestedGainMb <= 0) return 0
        // trueHeadroom is the hard ceiling: however much of K_TOTAL_BUDGET_MB
        // the EQ side hasn't already claimed. Never exceeded, period.
        val trueHeadroom = (K_TOTAL_BUDGET_MB - lastEqPeakGainMb).coerceAtLeast(0)
        // K_LOUDNESS_FLOOR_MB is a soft preference: use it only when there's
        // enough real headroom to afford it. If headroom is thinner than the
        // floor, headroom wins — it is always the smaller of the two here.
        val preferred = if (trueHeadroom >= K_LOUDNESS_FLOOR_MB) K_LOUDNESS_FLOOR_MB else trueHeadroom
        // Actual applied gain: whichever is smaller among what was asked
        // for, the soft-preferred floor, and true headroom — trueHeadroom
        // is included again explicitly so the guarantee holds regardless of
        // how preferred was computed above.
        return minOf(requestedGainMb, preferred, trueHeadroom)
    }

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

        // EQ bands are applied FIRST so lastEqPeakGainMb reflects the
        // current combined EQ-side gain (Bass Boost bump + Premium Sound
        // curve + bitrate compensation) before LoudnessEnhancer computes its
        // share of the shared budget below. Order matters here — computing
        // the loudness budget against a stale/previous EQ peak is what let
        // the two sides drift out of sync and stack past K_TOTAL_BUDGET_MB.
        _ap2(
            bassBoost = lastBassBoost,
            volNorm = lastVolNorm,
            bandGainsMb = lastBandGains,
            intensityFraction = effectiveFraction,
        )

        _applyLoudnessForPremium(effectiveFraction, active)
    }

    // Applies LoudnessEnhancer's gain for the Premium Sound / bass-boost-fade
    // path. Extracted out of _ap3 so reportSourceBitrate can also re-sync
    // LoudnessEnhancer after a bitrate change without re-running the
    // Virtualizer/BassBoost/limiter arming logic above it in _ap3 (which
    // would be redundant — those aren't affected by bitrate). Always call
    // _ap2 immediately before this so lastEqPeakGainMb is fresh.
    private fun _applyLoudnessForPremium(effectiveFraction: Float, active: Boolean) {
        if (loudnessHealthy) {
            loudnessEnhancer?.let { enhancer ->
                try {
                    val bassBoostOn = lastBassBoost
                    val premiumGain = (K_P3 * effectiveFraction).toInt()
                    val requestedGain = when {
                        active && bassBoostOn -> maxOf(premiumGain, BASS_BOOST_LOUDNESS_GAIN_MB)
                        active -> premiumGain
                        bassBoostOn -> BASS_BOOST_LOUDNESS_GAIN_MB
                        else -> null
                    }
                    // Budget-clamp against however much the EQ side is
                    // already spending, so LoudnessEnhancer + EQ combined
                    // never exceed K_TOTAL_BUDGET_MB — this is the fix for
                    // the crackle/glitch when Bass Boost + Premium Sound +
                    // custom EQ are all active together (see K_TOTAL_BUDGET_MB
                    // doc comment above).
                    val targetGain = requestedGain?.let { _loudnessBudgetMb(it) }
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
    }

    private fun _ap1(bassBoost: Boolean) {
        if (!loudnessHealthy) return
        val enhancer = loudnessEnhancer ?: return

        try {
            if (lastPremiumSound) return
            enhancer.enabled = bassBoost
            if (!bassBoost) return

            // Same shared-budget clamp as _ap3 — a custom EQ curve can
            // still be active here even with Premium Sound off, so
            // LoudnessEnhancer must still respect whatever the EQ side
            // (lastEqPeakGainMb) is already spending.
            val targetGain = _loudnessBudgetMb(BASS_BOOST_LOUDNESS_GAIN_MB)
            val fallbackGain = _loudnessBudgetMb(BASS_BOOST_LOUDNESS_GAIN_FALLBACK_MB)
            try {
                enhancer.setTargetGain(targetGain)
            } catch (e: Exception) {
                Log.w(TAG, "LoudnessEnhancer ${targetGain}mB rejected ($e) — retrying at ${fallbackGain}mB")
                try {
                    enhancer.setTargetGain(fallbackGain)
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
            // Track peak absolute gain for the shared LoudnessEnhancer
            // budget (see _loudnessBudgetMb) — only the boost side matters
            // here since cuts don't add to perceived-loudness/clip risk.
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
