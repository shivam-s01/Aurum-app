package com.aurum.music

/**
 * Premium Sound's tonal "voicing": turns (enabled, intensity, source bitrate) into
 * [AurumDspCore.Params]. Pure Kotlin (no Android deps) so it is unit-testable on a JVM.
 *
 * The previous voicing was only about +/-2 dB, and at the typical route/volume intensity
 * (~0.7) about +/-1.5 dB, with an overall level drop from the headroom pre-gain. That is
 * below what people hear in an A/B, so Premium Sound sounded like "no change". This voicing is
 * deliberately clearly audible while staying clean (the DSP's automatic headroom + look-ahead
 * limiter keep it from distorting).
 *
 * EQ band layout of [AurumDspCore] (index -> filter):
 *   0: low shelf 110 Hz   1: bell 230 Hz   2: bell 910 Hz   3: bell 3.6 kHz   4: high shelf 9 kHz
 * plus a dedicated bass shelf at 85 Hz, a side-signal widener (above ~250 Hz) and makeup gain.
 *
 * Full-intensity target (net response, mid level stays where it was so A/B is not "quieter"):
 *   - low end   : +3.5 dB @85 Hz shelf and +1.0 dB @110 Hz shelf  (about +4 dB sub/bass, tight)
 *   - low-mids  : -2.0 dB @230 Hz  (mud scoop so vocals/instruments are not thick)
 *   - mids      :  ~0 dB
 *   - presence  : +3.0 dB @3.6 kHz (clarity / vocal detail)
 *   - air       : +3.5 dB @9 kHz shelf (detail; reduced on low-bitrate sources)
 *   - width     : +45% side signal above 250 Hz (bass stays centred)
 *   - level     : +2.5 dB makeup on top of the DSP's automatic headroom, which brings the mids
 *                 back to unity; the look-ahead limiter catches the rest.
 */
object PremiumVoicing {

    private const val BASS_SHELF_DB = 3.5f
    private const val WIDEN = 0.45f
    private const val MAKEUP_DB = 2.5f

    private val BAND_DB = floatArrayOf(1.0f, -2.0f, 0.0f, 3.0f, 3.5f)

    // Low-bitrate (lossy) tilt in dB per band, at <= KBPS_FULL. Perceptual only.
    private val LOWBR_DB = floatArrayOf(0.0f, -0.2f, 0.4f, 0.3f, -0.2f)
    private const val KBPS_FULL = 96
    private const val KBPS_NONE = 192

    /** Fraction of the air shelf removed at full low-bitrate scale (codec artifacts live up there). */
    private const val AIR_CUT_AT_LOW_BITRATE = 0.5f

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
            var g = BAND_DB[b] * i
            if (b == AurumDspCore.BANDS - 1) g *= 1f - AIR_CUT_AT_LOW_BITRATE * lowBr
            g + LOWBR_DB[b] * lowBr
        }
        return AurumDspCore.Params(
            bandDb = bands,
            bassShelfDb = BASS_SHELF_DB * i,
            widen = WIDEN * i,
            makeupDb = MAKEUP_DB * i,
        )
    }
}
