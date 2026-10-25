package com.aurum.music

/**
 * "Spiritual Sound" voicing (formerly Premium Sound): turns (enabled, intensity, source bitrate)
 * into [AurumDspCore.Params]. Pure Kotlin (no Android deps) so it is unit-testable on a JVM.
 *
 * Goal: every track (Bollywood, DJ / club, bass-heavy, bright or harsh uploads) sounds warm,
 * spacious and calm, like a temple hall, with zero listening fatigue: no sharp highs, no ear
 * ringing, no harsh S / hi-hat edge, even at high volume and for hours.
 *
 * EQ band layout of [AurumDspCore] (index -> filter):
 *   0: low shelf 110 Hz   1: bell 230 Hz   2: bell 910 Hz   3: bell 3.6 kHz   4: high shelf 9 kHz
 * plus a dedicated bass shelf at 85 Hz, a side-signal widener (above ~250 Hz), a warm hall reverb
 * and makeup gain. The DSP's automatic headroom + look-ahead limiter keep it clean.
 *
 * Full-intensity target:
 *   - low end   : +2.4 dB @85 Hz shelf, +0.8 dB @110 Hz shelf (deep, round, not boomy)
 *   - low-mids  : -1.2 dB @230 Hz (keeps the reverb and bass from getting muddy)
 *   - mids      : -0.4 dB @910 Hz (removes nasal / honky edge)
 *   - presence  : -1.6 dB @3.6 kHz (this is the fatigue / ear-pain zone on DJ and loud masters)
 *   - air       : -3.2 dB @9 kHz shelf (silky highs; cut extra on low-bitrate sources where codec
 *                 artifacts live)
 *   - width     : +32% side signal above 250 Hz (bass stays centred)
 *   - space     : soft dark hall reverb, ~1.8 s tail, heavily high-damped
 *   - level     : +1.5 dB makeup on top of the DSP's automatic headroom
 */
object PremiumVoicing {

    private const val BASS_SHELF_DB = 2.4f
    private const val WIDEN = 0.32f
    private const val MAKEUP_DB = 1.5f
    private const val REVERB = 0.30f

    private val BAND_DB = floatArrayOf(0.8f, -1.2f, -0.4f, -1.6f, -3.2f)

    // Low-bitrate (lossy) tilt in dB per band, at <= KBPS_FULL. Extra smoothing of the top end.
    private val LOWBR_DB = floatArrayOf(0.0f, 0.0f, 0.2f, -0.4f, -1.2f)
    private const val KBPS_FULL = 96
    private const val KBPS_NONE = 192

    fun lowBitrateScale(kbps: Int): Float = when {
        kbps <= 0 || kbps >= KBPS_NONE -> 0f
        kbps <= KBPS_FULL -> 1f
        else -> 1f - (kbps - KBPS_FULL).toFloat() / (KBPS_NONE - KBPS_FULL).toFloat()
    }

    /** [intensity] 0..1 scales the whole effect. [kbps] <= 0 means unknown. */
    fun paramsFor(enabled: Boolean, intensity: Float, kbps: Int): AurumDspCore.Params {
        if (!enabled) return AurumDspCore.Params()
        val i = if (intensity.isFinite()) intensity.coerceIn(0f, 1f) else 1f
        val lowBr = lowBitrateScale(kbps)
        val bands = FloatArray(AurumDspCore.BANDS) { b ->
            BAND_DB[b] * i + LOWBR_DB[b] * lowBr
        }
        return AurumDspCore.Params(
            bandDb = bands,
            bassShelfDb = BASS_SHELF_DB * i,
            widen = WIDEN * i,
            makeupDb = MAKEUP_DB * i,
            reverb = REVERB * i,
        )
    }
}
