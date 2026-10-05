package com.aurum.music

import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Aurum's own in-app DSP for Premium Sound / Equalizer / Bass Boost / Volume Boost.
 *
 * WHY THIS EXISTS: the old implementation attached the phone vendor's AudioEffects
 * (Equalizer, LoudnessEnhancer, Virtualizer, BassBoost, DynamicsProcessing) to the
 * player's audio session. Those live inside the device audio HAL, differ per phone,
 * and get reset / re-routed / overloaded on every AudioTrack recreate, route change
 * and thermal throttle -> "plays fine for a while, then glitches". Tuning gains could
 * never fix that, because the problem was where the processing ran, not its values.
 *
 * This core runs inside the app, on the decoded PCM, with no vendor code:
 *
 *   input -> stereo widener (side > 250 Hz only) -> smoothed gain (makeup - headroom)
 *         -> 5-band EQ + premium bass shelf (TPT state-variable filters, double precision)
 *         -> look-ahead brick-wall limiter -> output
 *
 *  - Every parameter change is smoothed (40 ms) in the dB domain and biquad
 *    coefficients are recomputed from the smoothed value, so there is no zipper noise.
 *  - Headroom is automatic: the real peak of the combined EQ response is measured
 *    and part of it is subtracted up front, so boosts don't slam the limiter.
 *  - The limiter looks ahead 3 ms, so it never overshoots; attack is a smooth
 *    box-filtered ramp (no hard clipping), release is a slow one-pole (100 ms).
 *  - When every parameter is neutral the core is a pure delay line (bit-exact).
 *
 * Pure Kotlin on purpose (no Android / Media3 imports): it is unit-tested on a JVM.
 * [AurumDspAudioProcessor] is the thin Media3 wrapper around it.
 */
class AurumDspCore(private val smoothMs: Double = DEFAULT_SMOOTH_MS) {

    /** Immutable parameter set. [bandDb] has [BANDS] entries (dB). */
    class Params(
        bandDb: FloatArray = FloatArray(BANDS),
        val bassShelfDb: Float = 0f,
        val widen: Float = 0f,
        val makeupDb: Float = 0f,
    ) {
        val bandDb: FloatArray = bandDb.copyOf(BANDS)
    }

    companion object {
        const val BANDS = 5

        // 5 user bands + 1 dedicated "premium bass" shelf.
        private const val FILTERS = BANDS + 1
        private const val TICK = 32                  // control-rate: params updated every 32 frames
        private const val LOOKAHEAD_MS = 3.0
        private const val RELEASE_MS = 100.0
        /** Default time constant for parameter smoothing. */
        const val DEFAULT_SMOOTH_MS = 40.0
        private const val WIDEN_SPLIT_HZ = 250.0

        /** Limiter ceiling: -0.5 dBFS. */
        const val CEILING = 0.944f

        /**
         * Fraction of the EQ's positive peak that is pre-attenuated. 0.6 keeps the limiter
         * almost idle on normal material while not making EQ/Premium audibly quieter.
         */
        const val HEADROOM_FACTOR = 0.6

        private const val MAX_DB = 15f
        private const val DENORM_GUARD = 1e-20

        // 0 = low shelf, 1 = peaking, 2 = high shelf
        private val TYPE = intArrayOf(0, 1, 1, 1, 2, 0)
        private val FREQ = doubleArrayOf(110.0, 230.0, 910.0, 3600.0, 9000.0, 85.0)
        private const val PEAK_Q = 1.0
        private const val SHELF_Q = 0.7071067811865476

        private const val RESP_POINTS = 48

        private val UNITY = Params()
    }

    private val target = AtomicReference(UNITY)

    /** Thread-safe: may be called from any thread. */
    fun setParams(p: Params) {
        target.set(p)
    }

    // ── configuration ───────────────────────────────────────────────
    private var sr = 0
    private var ch = 0
    private var la = 0                       // look-ahead length in frames (L)

    // ── smoothed current values ─────────────────────────────────────
    private val curDb = FloatArray(FILTERS)
    private var curWiden = 0f
    private var curMakeup = 0f
    private var smoothK = 0.0
    private var headroomDb = 0.0
    private var headroomDirty = false
    private var tickCount = 0

    // ── filters (TPT / Cytomic state-variable filters) ──────────────
    // Chosen over direct-form biquads on purpose: the integrator states of an SVF do not
    // depend on the gain coefficient, so changing a band's gain while audio is flowing does
    // not produce the state-mismatch "zipper" a time-varying biquad does.
    private val fg = DoubleArray(FILTERS)
    private val fk = DoubleArray(FILTERS)
    private val fa1 = DoubleArray(FILTERS)
    private val fa2 = DoubleArray(FILTERS)
    private val fa3 = DoubleArray(FILTERS)
    // Output-mix coefficients. fm* = value in use right now, tm* = target for this tick,
    // dm* = per-sample step. They are interpolated sample-by-sample: a step in these
    // (output = m0*x + m1*bandpass + m2*lowpass) is what would otherwise click.
    private val fm0 = DoubleArray(FILTERS) { 1.0 }
    private val fm1 = DoubleArray(FILTERS)
    private val fm2 = DoubleArray(FILTERS)
    private val tm0 = DoubleArray(FILTERS) { 1.0 }
    private val tm1 = DoubleArray(FILTERS)
    private val tm2 = DoubleArray(FILTERS)
    private val dm0 = DoubleArray(FILTERS)
    private val dm1 = DoubleArray(FILTERS)
    private val dm2 = DoubleArray(FILTERS)
    private val act = BooleanArray(FILTERS)
    private val actIdx = IntArray(FILTERS)
    private var actCount = 0
    private val tanHalfFc = DoubleArray(FILTERS)     // tan(pi * fc / sr)
    private val ic1 = Array(2) { DoubleArray(FILTERS) }
    private val ic2 = Array(2) { DoubleArray(FILTERS) }

    // response-peak probe: tan(w/2) at RESP_POINTS log-spaced frequencies
    private val probeTan = DoubleArray(RESP_POINTS)

    // ── widener ─────────────────────────────────────────────────────
    private var sLow = 0.0
    private var sCoef = 0.0
    private var widenNow = 0f            // value in use (ramped per sample)
    private var widenStep = 0f

    // ── gain ramp ───────────────────────────────────────────────────
    private var gain = 1.0
    private var gainTo = 1.0
    private var gainStep = 0.0

    // ── limiter ─────────────────────────────────────────────────────
    private var gtRing = FloatArray(0)       // per-frame desired gain history
    private var boxRing = FloatArray(0)      // released-gain history (box filter)
    private var ti = 0
    private var sinceReduce = 0
    private var rVal = 1f
    private var boxSum = 0.0
    private var onesRun = 0
    private var relCoef = 0f

    // ── delay line (look-ahead) ─────────────────────────────────────
    private var ring = FloatArray(0)
    private var head = 0
    private var count = 0

    // ── bookkeeping ─────────────────────────────────────────────────
    private var phase = 0
    private var identity = true

    /** True if the last [process] call ran the active (non-bit-exact) path at least once. */
    var lastCallActive = false
        private set

    /** Frames received but not yet delivered (what [process] with flushing=true must drain). */
    val pendingFrames: Int get() = count

    val lookaheadFrames: Int get() = la

    // ════════════════════════════════════════════════════════════════
    // Setup
    // ════════════════════════════════════════════════════════════════

    fun configure(sampleRate: Int, channels: Int) {
        require(channels in 1..2) { "AurumDspCore supports 1 or 2 channels" }
        require(sampleRate in 8000..384000) { "unsupported sample rate $sampleRate" }
        sr = sampleRate
        ch = channels
        la = max(16, (sr * LOOKAHEAD_MS / 1000.0).roundToInt())
        smoothK = 1.0 - exp(-TICK.toDouble() / (sr * smoothMs / 1000.0))
        relCoef = (1.0 - exp(-1.0 / (sr * RELEASE_MS / 1000.0))).toFloat()
        sCoef = 1.0 - exp(-2.0 * Math.PI * WIDEN_SPLIT_HZ / sr)

        for (f in 0 until FILTERS) {
            val hz = min(FREQ[f], sr * 0.45)
            tanHalfFc[f] = kotlin.math.tan(Math.PI * hz / sr)
        }
        for (k in 0 until RESP_POINTS) {
            val hz = min(20.0 * (20000.0 / 20.0).pow(k.toDouble() / (RESP_POINTS - 1)), sr * 0.45)
            probeTan[k] = kotlin.math.tan(Math.PI * hz / sr)
        }
        gtRing = FloatArray(la)
        boxRing = FloatArray(la)
        ring = FloatArray(la * ch)
        for (f in 0 until FILTERS) {
            recompute(f)
            fm0[f] = tm0[f]; fm1[f] = tm1[f]; fm2[f] = tm2[f]
            dm0[f] = 0.0; dm1[f] = 0.0; dm2[f] = 0.0
        }
        rebuildActive()
        headroomDb = measurePeakDb().coerceAtLeast(0.0)
        resetState()
        gain = outGain()
        gainTo = gain
        gainStep = 0.0
    }

    /** Drops all audio history (seek / new stream). Parameters and their smoothing are kept. */
    fun reset() {
        if (ch == 0) return
        resetState()
    }

    private fun resetState() {
        for (c in 0..1) {
            ic1[c].fill(0.0)
            ic2[c].fill(0.0)
        }
        sLow = 0.0
        widenNow = curWiden
        widenStep = 0f
        ring.fill(0f)
        head = 0
        count = 0
        limiterToIdle()
        phase = 0
        identity = false
        tickCount = 0
        headroomDirty = true
    }

    private fun limiterToIdle() {
        gtRing.fill(1f)
        boxRing.fill(1f)
        ti = 0
        sinceReduce = la
        rVal = 1f
        boxSum = la.toDouble()
        onesRun = la
    }

    // ════════════════════════════════════════════════════════════════
    // Filters
    // ════════════════════════════════════════════════════════════════

    private fun recompute(f: Int) {
        val db = curDb[f].toDouble()
        if (db == 0.0) {
            if (act[f]) {
                ic1[0][f] = 0.0; ic1[1][f] = 0.0
                ic2[0][f] = 0.0; ic2[1][f] = 0.0
            }
            act[f] = false
            fm0[f] = 1.0; fm1[f] = 0.0; fm2[f] = 0.0
            tm0[f] = 1.0; tm1[f] = 0.0; tm2[f] = 0.0
            dm0[f] = 0.0; dm1[f] = 0.0; dm2[f] = 0.0
            return
        }
        act[f] = true
        val aa = 10.0.pow(db / 40.0)
        val g: Double
        val k: Double
        when (TYPE[f]) {
            1 -> {                                   // bell
                g = tanHalfFc[f]
                k = 1.0 / (PEAK_Q * aa)
                tm0[f] = 1.0
                tm1[f] = k * (aa * aa - 1.0)
                tm2[f] = 0.0
            }
            0 -> {                                   // low shelf
                g = tanHalfFc[f] / sqrt(aa)
                k = 1.0 / SHELF_Q
                tm0[f] = 1.0
                tm1[f] = k * (aa - 1.0)
                tm2[f] = aa * aa - 1.0
            }
            else -> {                                // high shelf
                g = tanHalfFc[f] * sqrt(aa)
                k = 1.0 / SHELF_Q
                tm0[f] = aa * aa
                tm1[f] = k * (1.0 - aa) * aa
                tm2[f] = 1.0 - aa * aa
            }
        }
        fg[f] = g
        fk[f] = k
        val a1 = 1.0 / (1.0 + g * (g + k))
        fa1[f] = a1
        fa2[f] = g * a1
        fa3[f] = g * g * a1
    }

    private fun rebuildActive() {
        var n = 0
        for (f in 0 until FILTERS) if (act[f]) actIdx[n++] = f
        actCount = n
    }

    /** Peak (dB) of the combined EQ magnitude response over 20 Hz..20 kHz. */
    private fun measurePeakDb(): Double {
        if (actCount == 0) return 0.0
        var peak = -1e9
        for (p in 0 until RESP_POINTS) {
            var db = 0.0
            for (n in 0 until actCount) {
                val f = actIdx[n]
                val om = probeTan[p] / fg[f]                 // normalised analog frequency
                val dr = 1.0 - om * om
                val di = fk[f] * om
                val den = dr * dr + di * di
                val re = tm0[f] + (tm1[f] * om * di + tm2[f] * dr) / den
                val im = (tm1[f] * om * dr - tm2[f] * di) / den
                db += 10.0 * log10(re * re + im * im)
            }
            if (db > peak) peak = db
        }
        return peak
    }

    private fun outGain(): Double =
        10.0.pow((curMakeup - HEADROOM_FACTOR * headroomDb) / 20.0)

    // ════════════════════════════════════════════════════════════════
    // Control (once per TICK frames)
    // ════════════════════════════════════════════════════════════════

    private fun sane(v: Float): Float = if (v.isFinite()) v.coerceIn(-MAX_DB, MAX_DB) else 0f

    private fun tickControl() {
        val t = target.get()
        var filtersChanged = false
        var activeSetChanged = false
        for (f in 0 until FILTERS) {
            val tgt = sane(if (f < BANDS) t.bandDb[f] else t.bassShelfDb)
            val c = curDb[f]
            if (c != tgt) {
                var n = (c + (tgt - c) * smoothK).toFloat()
                if (abs(tgt - n) < 0.002f) n = tgt
                curDb[f] = n
                val was = act[f]
                recompute(f)
                if (was != act[f]) activeSetChanged = true
                filtersChanged = true
            }
        }
        if (activeSetChanged) rebuildActive()

        val tw = if (t.widen.isFinite()) t.widen.coerceIn(0f, 1f) else 0f
        if (curWiden != tw) {
            var n = curWiden + (tw - curWiden) * smoothK.toFloat()
            if (abs(tw - n) < 0.0005f) n = tw
            curWiden = n
        }
        val tm = sane(t.makeupDb)
        if (curMakeup != tm) {
            var n = curMakeup + (tm - curMakeup) * smoothK.toFloat()
            if (abs(tm - n) < 0.002f) n = tm
            curMakeup = n
        }

        // Headroom is derived from the *smoothed* filters, re-measured every 4th tick
        // while they move (and once more when they settle).
        if (filtersChanged) {
            headroomDirty = true
            headroomDb = measurePeakDb().coerceAtLeast(0.0)
        } else if (headroomDirty) {
            headroomDb = measurePeakDb().coerceAtLeast(0.0)
            headroomDirty = false
        }
        tickCount++

        gainTo = outGain()
        gainStep = (gainTo - gain) / TICK
        for (n in 0 until actCount) {
            val f = actIdx[n]
            dm0[f] = (tm0[f] - fm0[f]) / TICK
            dm1[f] = (tm1[f] - fm1[f]) / TICK
            dm2[f] = (tm2[f] - fm2[f]) / TICK
        }
        widenStep = (curWiden - widenNow) / TICK

        var allZero = curWiden == 0f && curMakeup == 0f
        if (allZero) {
            for (f in 0 until FILTERS) if (curDb[f] != 0f) { allZero = false; break }
        }
        val limiterIdle = rVal == 1f && onesRun >= la
        val nowIdentity = allZero && limiterIdle && headroomDb == 0.0
        if (nowIdentity && !identity) {
            // entering bit-exact mode: drop stale (≈ -80 dB) filter tails
            for (c in 0..1) { ic1[c].fill(0.0); ic2[c].fill(0.0) }
            sLow = 0.0
            limiterToIdle()
            gain = 1.0; gainTo = 1.0; gainStep = 0.0
            widenNow = 0f; widenStep = 0f
        }
        identity = nowIdentity
    }

    // ════════════════════════════════════════════════════════════════
    // Audio
    // ════════════════════════════════════════════════════════════════

    private fun bq(c: Int, x: Double, ph: Int): Double {
        var v0 = x
        val s1 = ic1[c]
        val s2 = ic2[c]
        for (n in 0 until actCount) {
            val f = actIdx[n]
            val v3 = v0 - s2[f]
            val v1 = fa1[f] * s1[f] + fa2[f] * v3
            val v2 = s2[f] + fa2[f] * s1[f] + fa3[f] * v3
            s1[f] = 2.0 * v1 - s1[f]
            s2[f] = 2.0 * v2 - s2[f]
            val a = fm0[f] + dm0[f] * ph
            val b = fm1[f] + dm1[f] * ph
            val c2 = fm2[f] + dm2[f] * ph
            v0 = a * v0 + b * v1 + c2 * v2
        }
        return v0
    }

    /**
     * Processes [frames] interleaved frames in place and returns how many output frames were
     * written to the front of [data]. Because of the look-ahead, the first (lookahead-1) input
     * frames produce no output; they come out at the end via a flushing call
     * (pass [pendingFrames] zero frames with flushing = true).
     */
    fun process(data: FloatArray, frames: Int, flushing: Boolean = false): Int {
        if (ch == 0 || la == 0) return frames
        val cc = ch
        val laF = la
        var inPos = 0
        var outPos = 0
        var usedActive = false

        while (inPos < frames) {
            if (phase == 0) tickControl()
            val n = min(TICK - phase, frames - inPos)
            val bypass = identity
            if (!bypass) usedActive = true

            for (i in 0 until n) {
                val ph = phase + i + 1
                val ip = (inPos + i) * cc
                var x0 = data[ip].toDouble()
                var x1 = if (cc == 2) data[ip + 1].toDouble() else 0.0

                val y0: Float
                val y1: Float
                var lim = 1f

                if (bypass) {
                    y0 = x0.toFloat()
                    y1 = x1.toFloat()
                } else {
                    // widener (stereo only): boost side content above ~250 Hz
                    if (cc == 2) {
                        val m = (x0 + x1) * 0.5
                        val s = (x0 - x1) * 0.5
                        sLow += sCoef * (s - sLow)
                        val wv = widenNow + widenStep * ph
                        if (wv != 0f) {
                            val s2 = sLow + (s - sLow) * (1.0 + wv)
                            x0 = m + s2
                            x1 = m - s2
                        }
                    }
                    gain += gainStep
                    val g = gain
                    val v0 = bq(0, x0 * g + DENORM_GUARD, ph)
                    val v1 = if (cc == 2) bq(1, x1 * g + DENORM_GUARD, ph) else 0.0
                    y0 = v0.toFloat()
                    y1 = v1.toFloat()

                    // ── look-ahead limiter: gain computed for this frame, applied L-1 frames later
                    val pk = max(abs(y0), abs(y1))
                    val gt = if (pk > CEILING) CEILING / pk else 1f
                    val idx = ti
                    gtRing[idx] = gt
                    if (gt < 1f) sinceReduce = 0 else if (sinceReduce < laF) sinceReduce++
                    var m = 1f
                    if (sinceReduce < laF) {
                        for (k in 0 until laF) {
                            val v = gtRing[k]
                            if (v < m) m = v
                        }
                    }
                    if (m < rVal) {
                        rVal = m
                    } else {
                        rVal += (m - rVal) * relCoef
                        if (rVal > 0.999999f) rVal = 1f
                    }
                    boxSum += (rVal - boxRing[idx]).toDouble()
                    boxRing[idx] = rVal
                    ti = if (idx + 1 == laF) 0 else idx + 1
                    if (rVal == 1f) {
                        if (onesRun < laF) onesRun++
                        if (onesRun >= laF) boxSum = laF.toDouble()
                    } else {
                        onesRun = 0
                    }
                    lim = (boxSum / laF).toFloat()
                    if (lim > 1f) lim = 1f
                }

                // ── delay line
                val wp = ((head + count) % laF) * cc
                ring[wp] = y0
                if (cc == 2) ring[wp + 1] = y1
                count++
                if (count == laF || flushing) {
                    val rp = head * cc
                    data[outPos * cc] = ring[rp] * lim
                    if (cc == 2) data[outPos * cc + 1] = ring[rp + 1] * lim
                    outPos++
                    head = if (head + 1 == laF) 0 else head + 1
                    count--
                }
            }

            phase += n
            if (phase >= TICK) {
                phase = 0
                gain = gainTo
                widenNow = curWiden
                for (f in 0 until FILTERS) {
                    fm0[f] = tm0[f]; fm1[f] = tm1[f]; fm2[f] = tm2[f]
                }
            }
            inPos += n
        }
        lastCallActive = usedActive
        return outPos
    }
}
