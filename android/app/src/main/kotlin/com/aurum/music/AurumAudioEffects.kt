package com.aurum.music

import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
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
    }

    private var equalizer: Equalizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var currentSessionId: Int = 0

    // Health tracking — once an effect is rejected by the native side more
    // than once, stop touching it for the rest of the app session. Retrying
    // a half-corrupted native effect over and over is what caused repeated
    // playback breaks in the old just_audio version.
    private var loudnessHealthy = true
    private var equalizerHealthy = true

    // Last-applied settings, cached so we can re-apply them immediately
    // whenever the audio session ID changes (new ExoPlayer internal
    // session, e.g. after certain track transitions) without waiting for
    // Dart to call applySettings() again.
    private var lastBassBoost = false
    private var lastVolNorm = false
    private var lastBandGains: List<Int>? = null // millibels, one per band

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

        // Re-apply whatever the user last configured, since a fresh
        // Equalizer/LoudnessEnhancer instance always starts at defaults.
        applySettings(
            bassBoost = lastBassBoost,
            volNorm = lastVolNorm,
            bandGainsMb = lastBandGains,
        )
    }

    private fun releaseEffects() {
        try { equalizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        equalizer = null
        loudnessEnhancer = null
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
            eq.enabled = true
            val bandCount = eq.numberOfBands.toInt()
            if (bandCount <= 0) return

            val range = eq.bandLevelRange // [minMb, maxMb]
            val minMb = range[0].toInt()
            val maxMb = range[1].toInt()

            val savedBands = (0 until bandCount).map { i ->
                bandGainsMb?.getOrNull(i) ?: 0
            }
            val hasCustomCurve = savedBands.any { it != 0 }

            var rejectedBands = 0
            for (i in 0 until bandCount) {
                var gain = if (volNorm && !hasCustomCurve) 0 else savedBands[i]

                if (bassBoost) {
                    if (i == 0) gain += BASS_BOOST_SUB_BASS_EXTRA_MB
                    if (i == 1) gain += BASS_BOOST_BASS_EXTRA_MB
                }

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
