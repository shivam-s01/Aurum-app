package com.aurum.music

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.audiofx.Virtualizer
import android.util.Log
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

/**
 * Native Kotlin replacement for the just_audio-based AudioEffectsController
 * (audio_effects_controller.dart, now orphaned since AurumAudioHandler/
 * just_audio is gone). Same two hard guarantees as the old Dart version:
 *
 *   1. SELF-HEALING: if a native effect ever rejects a value, this class
 *      catches it, backs off, and if it happens again, permanently disables
 *      ONLY that effect for the rest of the session — never lets a
 *      rejected call propagate up into playback code.
 *
 *   2. ONE-WAY DEPENDENCY: AurumAudioEngine only ever calls
 *      `AurumAudioEffects.applySettings()` (on settings change, forwarded
 *      from Dart) and `attachTo(player)` (once, at construction). This
 *      class never reaches back into the engine, the queue, or playback
 *      state — effects bugs stay structurally contained here.
 *
 * DIFFERENCE FROM THE just_audio VERSION: just_audio's AndroidEqualizer/
 * AndroidLoudnessEnhancer had to be supplied to AudioPipeline at
 * AudioPlayer CONSTRUCTION time. Framework-level android.media.audiofx
 * effects instead attach to a numeric audioSessionId, which ExoPlayer
 * exposes as a normal (mutable, can change) property — so this class
 * re-attaches on every onAudioSessionIdChanged rather than needing the
 * player built around it.
 */
@UnstableApi
class AurumAudioEffects(private val player: ExoPlayer) {

    companion object {
        private const val TAG = "AurumAudioEffects"

        // Bass Boost strength, in millibels (100mB = 1dB), applied to
        // LoudnessEnhancer. Matches the old Dart version's dB values.
        private const val BASS_BOOST_LOUDNESS_GAIN_MB = 1000 // 10.0 dB
        private const val BASS_BOOST_LOUDNESS_GAIN_FALLBACK_MB = 600 // 6.0 dB

        // Extra EQ gain (millibels) stacked on the two lowest bands
        // (sub-bass, bass) when Bass Boost is on.
        private const val BASS_BOOST_SUB_BASS_EXTRA_MB = 700 // 7.0 dB
        private const val BASS_BOOST_BASS_EXTRA_MB = 500 // 5.0 dB

        // ── Premium Sound chain ──────────────────────────────────────────
        // Not a licensed Dolby/DTS pipeline (that requires an OEM-level
        // corporate partnership, not something directly integrable) — this
        // is a legally-clear, license-free DSP chain built entirely on
        // Android framework AudioFX effects (BassBoost, Virtualizer,
        // LoudnessEnhancer, Equalizer).
        //
        // TUNED DOWN (2026-07-20): first pass (Virtualizer 650, BassBoost
        // 550, +4.0dB loudness, +3.5dB treble peak) was audibly fatiguing
        // on long sessions — too much stacked high-shelf + loudness made
        // vocals harsh and bass boomy instead of clean. This pass targets
        // "clearly better than flat, never announces itself as an
        // effect": every gain here is deliberately conservative and stays
        // well inside headroom so nothing clips or hisses, on cheap
        // earphones or flagship phones alike.

        // BassBoost strength is 0-1000 (0=off, 1000=max), NOT millibels.
        // 550 was boomy/muddy on sub-bass-heavy tracks. 320 gives noticeably
        // deeper low-end without smearing the mix.
        private const val PREMIUM_BASS_BOOST_STRENGTH: Short = 320

        // Virtualizer strength is also 0-1000. 650 was too wide — caused a
        // hollow/phasey "out of head" feeling on some tracks/headphones.
        // 380 gives a subtle, natural width increase.
        private const val PREMIUM_VIRTUALIZER_STRENGTH: Short = 380

        // Loudness lift, kept small — this is a tone-shaping/clarity chain,
        // not a "make everything louder" chain. Perceived loudness mostly
        // comes from the EQ curve below, not from pushing overall gain.
        private const val PREMIUM_LOUDNESS_GAIN_MB = 150 // 1.5 dB

        // Presence/clarity EQ curve (millibels), applied additively on top
        // of the user's own EQ curve when Premium Sound is on. Mapped
        // proportionally across however many bands this device's
        // Equalizer actually reports — never a hardcoded band count.
        // Halved (or better) from the first pass across every band, and
        // the treble/"air" bands specifically pulled back hardest since
        // that's what reads as "sharp/tiring" on cheap earphones.
        private val PREMIUM_CURVE_MB = listOf(
            100, 50, -80, 0, 120, 180, 150, 100, 100, 120,
        )
    }

    private var equalizer: Equalizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var virtualizer: Virtualizer? = null
    private var nativeBassBoost: BassBoost? = null
    private var currentSessionId: Int = 0

    // Health tracking — once an effect is rejected by the native side more
    // than once, stop touching it for the rest of the app session. Retrying
    // a half-corrupted native effect over and over is what caused repeated
    // playback breaks in the old just_audio version.
    private var loudnessHealthy = true
    private var equalizerHealthy = true
    private var virtualizerHealthy = true
    private var nativeBassBoostHealthy = true

    // Last-applied settings, cached so we can re-apply them immediately
    // whenever the audio session ID changes (new ExoPlayer internal
    // session, e.g. after certain track transitions) without waiting for
    // Dart to call applySettings() again.
    private var lastBassBoost = false
    private var lastVolNorm = false
    private var lastBandGains: List<Int>? = null // millibels, one per band
    private var lastPremiumSound = false

    private val sessionIdListener = object : Player.Listener {
        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            if (audioSessionId == currentSessionId) return
            attachEffects(audioSessionId)
        }
    }

    init {
        player.addListener(sessionIdListener)
        val sid = player.audioSessionId
        if (sid != androidx.media3.common.C.AUDIO_SESSION_ID_UNSET) {
            attachEffects(sid)
        }
    }

    private fun attachEffects(sessionId: Int) {
        releaseEffects()
        currentSessionId = sessionId
        loudnessHealthy = true
        equalizerHealthy = true
        virtualizerHealthy = true
        nativeBassBoostHealthy = true

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
                // Speaker-safe mode lets the framework pick a virtualization
                // strategy appropriate for whatever output is actually
                // active (phone speaker vs. wired/BT headphones) instead of
                // forcing a headphone-style effect onto a speaker, which is
                // what causes the "hollow/phasey" artifact on-device.
                try { forceVirtualizationMode(Virtualizer.VIRTUALIZATION_MODE_AUTO) } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "Virtualizer attach failed for session $sessionId: $e — disabling for this session")
            virtualizerHealthy = false
        }

        try {
            nativeBassBoost = BassBoost(0, sessionId)
        } catch (e: Exception) {
            Log.w(TAG, "BassBoost attach failed for session $sessionId: $e — disabling for this session")
            nativeBassBoostHealthy = false
        }

        // Re-apply whatever the user last configured, since fresh effect
        // instances always start at defaults.
        applySettings(
            bassBoost = lastBassBoost,
            volNorm = lastVolNorm,
            bandGainsMb = lastBandGains,
        )
        applyPremiumSound(lastPremiumSound)
    }

    private fun releaseEffects() {
        try { equalizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        try { virtualizer?.release() } catch (_: Exception) {}
        try { nativeBassBoost?.release() } catch (_: Exception) {}
        equalizer = null
        loudnessEnhancer = null
        virtualizer = null
        nativeBassBoost = null
    }

    /**
     * @param bassBoost whether Bass Boost is enabled
     * @param volNorm whether Volume Normalization is enabled (flattens to a
     *   neutral curve when the user hasn't set a custom EQ)
     * @param bandGainsMb per-band gains in millibels, indexed to match
     *   Equalizer.getNumberOfBands(); null/empty means "no custom curve".
     *   Caller (Dart, via AurumEngineChannelHandler) is expected to send
     *   values already converted from dB (Dart-side slider unit) to
     *   millibels — see AurumEngineChannelHandler's setEqualizerBands.
     */
    fun applySettings(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?) {
        lastBassBoost = bassBoost
        lastVolNorm = volNorm
        lastBandGains = bandGainsMb

        applyLoudnessEnhancer(bassBoost)
        applyEqualizer(bassBoost = bassBoost, volNorm = volNorm, bandGainsMb = bandGainsMb)
    }

    /**
     * "Premium Sound" — single toggle, independent of the older Bass
     * Boost/Volume Normalization/manual EQ controls (it composes with them
     * rather than replacing them). Turns on Virtualizer + native BassBoost,
     * a small extra LoudnessEnhancer gain, and stacks a presence/clarity
     * curve on top of the Equalizer. Every sub-effect follows this file's
     * existing self-healing rule: if the native side rejects it, back off
     * and disable only that piece, never crash playback.
     */
    fun applyPremiumSound(enabled: Boolean) {
        lastPremiumSound = enabled

        // Virtualizer: spatial width
        if (virtualizerHealthy) {
            virtualizer?.let { v ->
                try {
                    v.enabled = enabled
                    if (enabled) {
                        try {
                            v.setStrength(PREMIUM_VIRTUALIZER_STRENGTH)
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

        // Native BassBoost: deep low-end, separate DSP from the manual EQ
        // sub-bass boost and from LoudnessEnhancer, so this stays clean
        // instead of triple-stacking gain into distortion.
        if (nativeBassBoostHealthy) {
            nativeBassBoost?.let { bb ->
                try {
                    bb.enabled = enabled
                    if (enabled) {
                        try {
                            bb.setStrength(PREMIUM_BASS_BOOST_STRENGTH)
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

        // Small extra loudness lift, additive with the Bass-Boost-toggle's
        // own LoudnessEnhancer gain (LoudnessEnhancer's setTargetGain is
        // idempotent/overwriting, not additive-on-call, so when Bass Boost
        // is also on we take the max rather than summing to avoid an
        // unexpectedly aggressive gain).
        if (loudnessHealthy) {
            loudnessEnhancer?.let { enhancer ->
                try {
                    val bassBoostOn = lastBassBoost
                    val targetGain = when {
                        enabled && bassBoostOn -> maxOf(PREMIUM_LOUDNESS_GAIN_MB, BASS_BOOST_LOUDNESS_GAIN_MB)
                        enabled -> PREMIUM_LOUDNESS_GAIN_MB
                        bassBoostOn -> BASS_BOOST_LOUDNESS_GAIN_MB
                        else -> null
                    }
                    if (targetGain != null) {
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

        // Re-run the Equalizer so the premium presence curve stacks (or
        // un-stacks) on top of whatever the user's own EQ/bass-boost state
        // currently is.
        applyEqualizer(bassBoost = lastBassBoost, volNorm = lastVolNorm, bandGainsMb = lastBandGains)
    }

    private fun applyLoudnessEnhancer(bassBoost: Boolean) {
        if (!loudnessHealthy) return
        val enhancer = loudnessEnhancer ?: return

        try {
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

    private fun applyEqualizer(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?) {
        if (!equalizerHealthy) return
        val eq = equalizer ?: return

        try {
            val bandCount = eq.numberOfBands.toInt()
            if (bandCount <= 0) return

            val savedBandsPreview = (0 until bandCount).map { i ->
                bandGainsMb?.getOrNull(i) ?: 0
            }
            val hasCustomCurve = savedBandsPreview.any { it != 0 }
            val premiumOn = lastPremiumSound

            // Heat/battery: android.media.audiofx.Equalizer runs its DSP on
            // every audio sample while enabled=true, regardless of whether
            // any band actually deviates from flat. If the user has no
            // custom curve, bass boost is off, AND Premium Sound is off,
            // there is nothing for the equalizer to do — fully disable it
            // instead of leaving it enabled at all-zero gains, which was
            // silently burning CPU on every song for users who never touch
            // the EQ screen.
            if (!hasCustomCurve && !bassBoost && !premiumOn) {
                eq.enabled = false
                return
            }

            eq.enabled = true

            val range = eq.bandLevelRange // [minMb, maxMb]
            val minMb = range[0].toInt()
            val maxMb = range[1].toInt()

            val savedBands = savedBandsPreview

            // Premium Sound's presence/clarity curve, resampled from its
            // fixed 10-point definition onto however many bands THIS
            // device's Equalizer actually reports (never assume 10 bands).
            fun premiumGainFor(bandIndex: Int): Int {
                if (!premiumOn) return 0
                if (bandCount <= 1) return PREMIUM_CURVE_MB[0]
                val fraction = bandIndex.toFloat() / (bandCount - 1).toFloat()
                val srcIndex = (fraction * (PREMIUM_CURVE_MB.size - 1)).toInt()
                    .coerceIn(0, PREMIUM_CURVE_MB.size - 1)
                return PREMIUM_CURVE_MB[srcIndex]
            }

            var rejectedBands = 0
            for (i in 0 until bandCount) {
                var gain = if (volNorm && !hasCustomCurve) 0 else savedBands[i]

                if (bassBoost) {
                    if (i == 0) gain += BASS_BOOST_SUB_BASS_EXTRA_MB
                    if (i == 1) gain += BASS_BOOST_BASS_EXTRA_MB
                }

                gain += premiumGainFor(i)

                // Clamp to THIS device's actual reported range — never a
                // hardcoded number, matching the just_audio version's
                // reasoning: a mismatched hardcoded clamp is exactly what
                // causes "bad parameter value" native crashes.
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

    /** Number of bands + each band's center frequency (Hz) + the device's
     *  gain range (millibels) — sent to Dart once so the EQ slider UI can
     *  build itself around this device's real capabilities instead of an
     *  assumed band count. Returns null if the Equalizer never attached. */
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

    fun dispose() {
        player.removeListener(sessionIdListener)
        releaseEffects()
    }
}
