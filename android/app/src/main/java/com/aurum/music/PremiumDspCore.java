package com.aurum.music;

import java.nio.ByteBuffer;

/**
 * Premium Sound DSP — runs INSIDE the app's own audio pipeline (as a Media3
 * AudioProcessor, see PremiumSoundProcessor.kt) instead of on top of vendor
 * android.media.audiofx effects.
 *
 * WHY THIS EXISTS (root cause of "Premium Sound on -> some time fine -> then
 * audio glitch"): the old implementation attached FIVE platform effects to the
 * player's audio session (Equalizer, LoudnessEnhancer, Virtualizer, BassBoost,
 * DynamicsProcessing). Those run inside the device vendor's audio HAL / mixer
 * thread. They are re-initialised by the OS whenever the AudioTrack is
 * re-created (every sample-rate change between tracks, output route change,
 * pause/resume) and the Virtualizer/BassBoost/DynamicsProcessing implementations
 * on many phones (MediaTek / Samsung / Xiaomi) are CPU-heavy and not stable over
 * long sessions, particularly once the SoC thermally throttles. When the mixer
 * thread misses a deadline the result is exactly the reported crackle/glitch.
 * No amount of gain tuning could fix that, because the instability is in the
 * effect chain itself.
 *
 * This class replaces all of it with a small, deterministic, allocation-free
 * software chain that lives in the app process:
 *
 *   headroom gain -> low shelf -> 10 peaking bands (tonal curve + low-bitrate
 *   compensation) -> gentle mid/side widening -> look-free soft limiter ->
 *   soft-clip safety
 *
 * Properties:
 *  - no vendor code, no audio session, no AudioEffect objects -> nothing for the
 *    OS to invalidate or reset, identical on every device;
 *  - toggling is a 200 ms equal-power-free linear dry/wet crossfade (no click);
 *  - while OFF the processor is a plain memcpy (zero DSP cost, bit-exact);
 *  - output can never exceed full scale (limiter + tanh soft-clip), so it cannot
 *    produce digital clipping crackle even on loud masters;
 *  - cost is ~11 biquads per channel (a few million MACs per second of audio),
 *    negligible next to decoding, so it cannot starve the audio thread.
 *
 * Pure Java with no Android dependencies so it can be unit tested on a JVM.
 */
final class PremiumDspCore {

    // ── Tuning ────────────────────────────────────────────────────────────
    // Centre frequencies of the ten tonal bands (Hz).
    private static final double[] BAND_HZ = {
        31.5, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
    };
    private static final double BAND_Q = 1.2;

    // Tonal target in dB at full intensity: tight low end, light mud scoop in
    // the low mids, forward-but-not-shouty presence, controlled air. (Same
    // shape as the previous curve, scaled so it is actually audible now that
    // it is no longer split across the device's 5-band hardware equalizer.)
    private static final double[] CURVE_DB = {
        0.30, 0.10, -0.70, 0.30, 0.90, 1.10, 0.90, 0.60, 0.10, -0.20,
    };

    // Extra tilt for low-bitrate (lossy, dull-sounding) sources, dB at <=96 kbps.
    private static final double[] LOWBR_DB = {
        0.0, 0.0, -0.20, 0.10, 0.40, 0.50, 0.30, 0.0, -0.20, -0.20,
    };
    private static final int KBPS_FULL = 96;   // full compensation at/below
    private static final int KBPS_NONE = 192;  // none at/above

    private static final double BASS_SHELF_HZ = 95.0;
    private static final double BASS_SHELF_DB = 1.5;
    private static final double WIDEN_AMOUNT = 0.12; // side-channel boost (12%) at full intensity

    // Fraction of the filter chain's worst-case boost that is taken back as
    // headroom before the filters (rest is covered by the limiter).
    private static final double HEADROOM_FRACTION = 0.40;

    private static final double LIMIT_THRESHOLD = 0.97;
    private static final double LIMIT_ATTACK_S = 0.0005;
    private static final double LIMIT_RELEASE_S = 0.120;
    private static final double SOFTCLIP_KNEE = 0.93;

    private static final double CROSSFADE_S = 0.200;

    private static final int MAX_BIQUADS = BAND_HZ.length + 1; // + low shelf
    private static final int RESPONSE_POINTS = 128;

    // ── Parameters (written from any thread, read on the audio thread) ───
    private volatile boolean paramEnabled = false;
    private volatile float paramIntensity = 1f;
    private volatile int paramKbps = 0;

    // ── Audio-thread state ───────────────────────────────────────────────
    private int sampleRate = 0;
    private int channels = 0;

    private boolean appliedEnabled = false;
    private int appliedIntensityQ = -1;
    private int appliedKbps = -1;
    private int appliedRate = -1;

    private int biquadCount = 0;
    private final double[] b0 = new double[MAX_BIQUADS];
    private final double[] b1 = new double[MAX_BIQUADS];
    private final double[] b2 = new double[MAX_BIQUADS];
    private final double[] a1 = new double[MAX_BIQUADS];
    private final double[] a2 = new double[MAX_BIQUADS];
    // [channel][biquad]
    private final double[][] z1 = new double[2][MAX_BIQUADS];
    private final double[][] z2 = new double[2][MAX_BIQUADS];

    private double preGain = 1.0;       // current (smoothed)
    private double preGainTarget = 1.0;  // desired
    private double preCoef = 0.0;
    private double widen = 0.0;

    private double limiterEnv = 1.0;
    private double attackCoef = 0.0;
    private double releaseCoef = 0.0;

    private double mix = 0.0;       // 0 = dry, 1 = fully processed
    private double mixTarget = 0.0;
    private double mixStep = 0.0;

    // ── Control API ──────────────────────────────────────────────────────

    /** Thread-safe. intensity 0..1 scales the whole effect; kbps<=0 means unknown. */
    void setParams(boolean enabled, float intensity, int kbps) {
        paramIntensity = Math.max(0f, Math.min(1f, intensity));
        paramKbps = kbps;
        paramEnabled = enabled;
    }

    /** Audio thread (processor configure). */
    void configure(int sampleRateHz, int channelCount) {
        sampleRate = sampleRateHz;
        channels = Math.max(1, Math.min(2, channelCount));
        attackCoef = 1.0 - Math.exp(-1.0 / (LIMIT_ATTACK_S * sampleRateHz));
        releaseCoef = 1.0 - Math.exp(-1.0 / (LIMIT_RELEASE_S * sampleRateHz));
        mixStep = 1.0 / (CROSSFADE_S * sampleRateHz);
        preCoef = 1.0 - Math.exp(-1.0 / (0.030 * sampleRateHz));
        appliedRate = -1; // force coefficient rebuild
        resetState();
        mix = paramEnabled ? 1.0 : 0.0;
        mixTarget = mix;
    }

    /** Audio thread: seek / track change / format change. Snaps without a fade. */
    void flush() {
        resetState();
        mix = paramEnabled ? 1.0 : 0.0;
        mixTarget = mix;
    }

    void reset() {
        resetState();
        sampleRate = 0;
        mix = 0.0;
        mixTarget = 0.0;
    }

    private void resetState() {
        for (int c = 0; c < 2; c++) {
            java.util.Arrays.fill(z1[c], 0.0);
            java.util.Arrays.fill(z2[c], 0.0);
        }
        limiterEnv = 1.0;
        preGain = preGainTarget;
    }

    // ── Processing ───────────────────────────────────────────────────────

    /**
     * Processes every whole frame remaining in {@code in} into {@code out}
     * (which must have at least as much remaining space). Both buffers are
     * native-order, as guaranteed by Media3's AudioProcessor contract.
     * Leaves {@code in} fully consumed. The caller flips {@code out}.
     */
    void process(ByteBuffer in, ByteBuffer out, boolean isFloat) {
        if (sampleRate <= 0) {
            out.put(in);
            return;
        }
        syncParams();

        // Fully off and not fading: bit-exact bulk copy, zero DSP cost.
        if (mix <= 0.0 && mixTarget <= 0.0) {
            out.put(in);
            return;
        }

        final int bytesPerSample = isFloat ? 4 : 2;
        final int frameSize = bytesPerSample * channels;
        final int frames = in.remaining() / frameSize;

        if (channels == 2) {
            processStereo(in, out, isFloat, frames);
        } else {
            processMono(in, out, isFloat, frames);
        }
        // Any trailing partial frame (should never happen) is passed through
        // untouched so the byte count in == byte count out always holds.
        if (in.hasRemaining()) out.put(in);

        sanitizeState();
    }

    private void processStereo(ByteBuffer in, ByteBuffer out, boolean isFloat, int frames) {
        final int n = biquadCount;
        final double w = widen;
        final double[] zl1 = z1[0], zl2 = z2[0], zr1 = z1[1], zr2 = z2[1];

        for (int f = 0; f < frames; f++) {
            stepMix();
            preGain += (preGainTarget - preGain) * preCoef;
            final double pre = preGain;
            final double dryL, dryR;
            if (isFloat) {
                dryL = in.getFloat();
                dryR = in.getFloat();
            } else {
                dryL = in.getShort() * (1.0 / 32768.0);
                dryR = in.getShort() * (1.0 / 32768.0);
            }

            double l = dryL * pre;
            double r = dryR * pre;
            for (int k = 0; k < n; k++) {
                double y = b0[k] * l + zl1[k];
                zl1[k] = b1[k] * l - a1[k] * y + zl2[k];
                zl2[k] = b2[k] * l - a2[k] * y;
                l = y;
                y = b0[k] * r + zr1[k];
                zr1[k] = b1[k] * r - a1[k] * y + zr2[k];
                zr2[k] = b2[k] * r - a2[k] * y;
                r = y;
            }

            if (w > 0.0) {
                final double m = 0.5 * (l + r);
                final double s = 0.5 * (l - r) * (1.0 + w);
                l = m + s;
                r = m - s;
            }

            // Stereo-linked limiter, smooth attack/release (no hard gain steps).
            final double peak = Math.max(Math.abs(l), Math.abs(r));
            final double want = peak > LIMIT_THRESHOLD ? LIMIT_THRESHOLD / peak : 1.0;
            limiterEnv += (want - limiterEnv) * (want < limiterEnv ? attackCoef : releaseCoef);
            l = softClip(l * limiterEnv);
            r = softClip(r * limiterEnv);

            final double outL = dryL + (l - dryL) * mix;
            final double outR = dryR + (r - dryR) * mix;
            if (isFloat) {
                out.putFloat((float) outL);
                out.putFloat((float) outR);
            } else {
                out.putShort(toS16(outL));
                out.putShort(toS16(outR));
            }
        }
    }

    private void processMono(ByteBuffer in, ByteBuffer out, boolean isFloat, int frames) {
        final int n = biquadCount;
        final double[] zm1 = z1[0], zm2 = z2[0];

        for (int f = 0; f < frames; f++) {
            stepMix();
            preGain += (preGainTarget - preGain) * preCoef;
            final double pre = preGain;
            final double dry = isFloat ? in.getFloat() : in.getShort() * (1.0 / 32768.0);

            double x = dry * pre;
            for (int k = 0; k < n; k++) {
                final double y = b0[k] * x + zm1[k];
                zm1[k] = b1[k] * x - a1[k] * y + zm2[k];
                zm2[k] = b2[k] * x - a2[k] * y;
                x = y;
            }

            final double peak = Math.abs(x);
            final double want = peak > LIMIT_THRESHOLD ? LIMIT_THRESHOLD / peak : 1.0;
            limiterEnv += (want - limiterEnv) * (want < limiterEnv ? attackCoef : releaseCoef);
            x = softClip(x * limiterEnv);

            final double o = dry + (x - dry) * mix;
            if (isFloat) {
                out.putFloat((float) o);
            } else {
                out.putShort(toS16(o));
            }
        }
    }

    private void stepMix() {
        if (mix < mixTarget) {
            mix = Math.min(mixTarget, mix + mixStep);
        } else if (mix > mixTarget) {
            mix = Math.max(mixTarget, mix - mixStep);
        }
    }

    private static double softClip(double x) {
        final double a = Math.abs(x);
        if (a <= SOFTCLIP_KNEE) return x;
        final double room = 1.0 - SOFTCLIP_KNEE;
        final double y = SOFTCLIP_KNEE + room * Math.tanh((a - SOFTCLIP_KNEE) / room);
        return x < 0 ? -y : y;
    }

    private static short toS16(double v) {
        long q = Math.round(v * 32768.0);
        if (q > 32767) q = 32767;
        else if (q < -32768) q = -32768;
        return (short) q;
    }

    /** Guards against a poisoned filter state ever producing a persistent glitch. */
    private void sanitizeState() {
        boolean bad = !(limiterEnv > 0.0 && limiterEnv <= 1.0);
        for (int c = 0; c < channels && !bad; c++) {
            for (int k = 0; k < biquadCount; k++) {
                final double a = z1[c][k];
                final double b = z2[c][k];
                if (!(Math.abs(a) < 1.0e6) || !(Math.abs(b) < 1.0e6)) {
                    bad = true;
                    break;
                }
                // Flush denormals (slow on some cores) to zero.
                if (Math.abs(a) < 1.0e-20) z1[c][k] = 0.0;
                if (Math.abs(b) < 1.0e-20) z2[c][k] = 0.0;
            }
        }
        if (bad) resetState();
    }

    // ── Parameter -> coefficients ────────────────────────────────────────

    private void syncParams() {
        final boolean en = paramEnabled;
        final int iq = Math.round(paramIntensity * 100f);
        final int kbps = paramKbps;

        if (iq != appliedIntensityQ || kbps != appliedKbps || sampleRate != appliedRate) {
            rebuild(iq / 100.0, kbps);
            appliedIntensityQ = iq;
            appliedKbps = kbps;
            appliedRate = sampleRate;
        }
        if (en != appliedEnabled) {
            appliedEnabled = en;
            mixTarget = en ? 1.0 : 0.0;
            // Starting from fully dry: make sure the filters start clean.
            if (en && mix <= 0.0) resetState();
        }
    }

    private static double lowBitrateScale(int kbps) {
        if (kbps <= 0 || kbps >= KBPS_NONE) return 0.0;
        if (kbps <= KBPS_FULL) return 1.0;
        return 1.0 - (double) (kbps - KBPS_FULL) / (double) (KBPS_NONE - KBPS_FULL);
    }

    private void rebuild(double intensity, int kbps) {
        final double lowBr = lowBitrateScale(kbps);
        final double nyquistLimit = 0.45 * sampleRate;
        // Fixed slot layout (slot 0 = low shelf, 1..10 = bands). A band that is
        // not needed is an exact identity filter instead of being removed, so
        // slot <-> filter-state mapping never shifts when intensity or the
        // source bitrate changes (no state mismatch -> no click).
        final double shelfDb = BASS_SHELF_DB * intensity;
        if (shelfDb > 0.01) {
            designLowShelf(0, BASS_SHELF_HZ, shelfDb);
        } else {
            designIdentity(0);
        }
        for (int i = 0; i < BAND_HZ.length; i++) {
            final double db = CURVE_DB[i] * intensity + LOWBR_DB[i] * lowBr;
            if (Math.abs(db) < 0.01 || BAND_HZ[i] >= nyquistLimit) {
                designIdentity(i + 1);
            } else {
                designPeaking(i + 1, BAND_HZ[i], BAND_Q, db);
            }
        }
        biquadCount = MAX_BIQUADS;

        // Worst-case boost of the whole chain -> headroom so boosted material
        // doesn't pin the limiter.
        double maxDb = 0.0;
        final double fMax = Math.min(20000.0, nyquistLimit);
        for (int p = 0; p < RESPONSE_POINTS; p++) {
            final double f = 20.0 * Math.pow(fMax / 20.0, p / (double) (RESPONSE_POINTS - 1));
            maxDb = Math.max(maxDb, chainResponseDb(f));
        }
        preGainTarget = Math.pow(10.0, -HEADROOM_FRACTION * maxDb / 20.0);
        widen = channels == 2 ? WIDEN_AMOUNT * intensity : 0.0;
    }

    private double chainResponseDb(double hz) {
        final double w = 2.0 * Math.PI * hz / sampleRate;
        final double cw = Math.cos(w), sw = Math.sin(w);
        final double c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
        double db = 0.0;
        for (int k = 0; k < biquadCount; k++) {
            final double nr = b0[k] + b1[k] * cw + b2[k] * c2;
            final double ni = -(b1[k] * sw + b2[k] * s2);
            final double dr = 1.0 + a1[k] * cw + a2[k] * c2;
            final double di = -(a1[k] * sw + a2[k] * s2);
            final double mag = Math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
            db += 20.0 * Math.log10(mag);
        }
        return db;
    }

    private void designIdentity(int k) {
        b0[k] = 1.0;
        b1[k] = 0.0;
        b2[k] = 0.0;
        a1[k] = 0.0;
        a2[k] = 0.0;
    }

    // RBJ audio-EQ-cookbook designs, normalised by a0.
    private void designPeaking(int k, double hz, double q, double db) {
        final double A = Math.pow(10.0, db / 40.0);
        final double w0 = 2.0 * Math.PI * hz / sampleRate;
        final double cs = Math.cos(w0);
        final double alpha = Math.sin(w0) / (2.0 * q);
        final double a0 = 1.0 + alpha / A;
        b0[k] = (1.0 + alpha * A) / a0;
        b1[k] = (-2.0 * cs) / a0;
        b2[k] = (1.0 - alpha * A) / a0;
        a1[k] = (-2.0 * cs) / a0;
        a2[k] = (1.0 - alpha / A) / a0;
    }

    private void designLowShelf(int k, double hz, double db) {
        final double A = Math.pow(10.0, db / 40.0);
        final double w0 = 2.0 * Math.PI * hz / sampleRate;
        final double cs = Math.cos(w0);
        final double alpha = Math.sin(w0) / 2.0 * Math.sqrt(2.0); // shelf slope S = 1
        final double tsA = 2.0 * Math.sqrt(A) * alpha;
        final double a0 = (A + 1.0) + (A - 1.0) * cs + tsA;
        b0[k] = A * ((A + 1.0) - (A - 1.0) * cs + tsA) / a0;
        b1[k] = 2.0 * A * ((A - 1.0) - (A + 1.0) * cs) / a0;
        b2[k] = A * ((A + 1.0) - (A - 1.0) * cs - tsA) / a0;
        a1[k] = -2.0 * ((A - 1.0) + (A + 1.0) * cs) / a0;
        a2[k] = ((A + 1.0) + (A - 1.0) * cs - tsA) / a0;
    }
}
