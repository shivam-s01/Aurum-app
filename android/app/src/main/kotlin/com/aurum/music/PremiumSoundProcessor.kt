package com.aurum.music

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.min

/**
 * Media3 AudioProcessor that runs Premium Sound's in-app DSP ([AurumDspCore] + [PremiumVoicing])
 * on the player's decoded PCM, instead of vendor android.media.audiofx effects.
 *
 * Installed in DefaultAudioSink's PCM pipeline by AurumAudioEngine's RenderersFactory. Media3 never
 * runs processors on an offloaded / passthrough AudioTrack, which is why the engine drops offload
 * the moment Premium Sound is wanted (AurumAudioEffects.onEffectsAboutToAttach).
 *
 * Stays "active" for 16-bit / float, mono / stereo input so toggling Premium Sound never needs a
 * sink reconfiguration (that would be an audible gap): with Premium off every parameter is neutral
 * and the DSP is a bit-exact delay line. Any other PCM layout reports inactive (NOT_SET) and is
 * simply skipped, never an error.
 *
 * 16-bit output is TPDF-dithered, but only while the DSP is actually altering the signal.
 *
 * Diagnostics: a few lines are written to AurumDiagnosticLog (tag PREMIUM_DSP) on configure /
 * parameter change / first processed buffer, so it can be verified on a real phone without adb.
 */
@UnstableApi
class PremiumSoundProcessor : BaseAudioProcessor() {

    companion object {
        private const val BLOCK_FRAMES = 2048
        private const val INV_32768 = 1f / 32768f
        private const val LOG_TAG = "PREMIUM_DSP"

        // Premium fades in/out over roughly a second (time constant, so ~95% after ~3x this).
        private const val FADE_MS = 250.0
    }

    private val core = AurumDspCore(smoothMs = FADE_MS)
    private val block = FloatArray(BLOCK_FRAMES * 2)
    private var tailPending = false
    private var rng = 0x2545F491

    @Volatile private var wantedEnabled = false
    @Volatile private var wantedIntensity = 1f
    @Volatile private var wantedKbps = 0

    // diagnostics (audio thread only)
    private var loggedFirstBuffer = false

    /** Thread-safe; takes effect on the next audio buffer, faded in/out smoothly. */
    fun setParams(enabled: Boolean, intensity: Float, sourceKbps: Int) {
        val changed = enabled != wantedEnabled
        wantedEnabled = enabled
        wantedIntensity = intensity
        wantedKbps = sourceKbps
        core.setParams(PremiumVoicing.paramsFor(enabled, intensity, sourceKbps))
        if (changed) {
            diag("setParams enabled=$enabled intensity=${"%.2f".format(intensity)} kbps=$sourceKbps")
            loggedFirstBuffer = false
        }
    }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        val encodingOk = inputAudioFormat.encoding == C.ENCODING_PCM_16BIT ||
            inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        val channelsOk = inputAudioFormat.channelCount in 1..2
        val rateOk = inputAudioFormat.sampleRate in 8000..384000
        if (!encodingOk || !channelsOk || !rateOk) {
            diag(
                "NOT processing this stream: encoding=${inputAudioFormat.encoding} " +
                    "channels=${inputAudioFormat.channelCount} rate=${inputAudioFormat.sampleRate}",
            )
            return AudioProcessor.AudioFormat.NOT_SET
        }
        core.configure(inputAudioFormat.sampleRate, inputAudioFormat.channelCount)
        loggedFirstBuffer = false
        diag(
            "configured rate=${inputAudioFormat.sampleRate} channels=${inputAudioFormat.channelCount} " +
                "encoding=${if (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) "float" else "pcm16"} " +
                "premiumWanted=$wantedEnabled",
        )
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val fmt = inputAudioFormat
        val ch = fmt.channelCount
        val isFloat = fmt.encoding == C.ENCODING_PCM_FLOAT
        val bytesPerFrame = fmt.bytesPerFrame
        val totalFrames = inputBuffer.remaining() / bytesPerFrame

        val out = replaceOutputBuffer(totalFrames * bytesPerFrame)
        val savedOrder = inputBuffer.order()
        inputBuffer.order(ByteOrder.nativeOrder())
        var left = totalFrames
        while (left > 0) {
            val n = min(left, BLOCK_FRAMES)
            val samples = n * ch
            if (isFloat) {
                for (i in 0 until samples) block[i] = inputBuffer.getFloat()
            } else {
                for (i in 0 until samples) block[i] = inputBuffer.getShort() * INV_32768
            }
            val written = core.process(block, n)
            if (written > 0) writeSamples(out, written * ch, isFloat, core.lastCallActive)
            left -= n
        }
        inputBuffer.order(savedOrder)
        // Media3 only ever queues whole frames; drop a stray partial frame defensively.
        inputBuffer.position(inputBuffer.limit())
        out.flip()

        if (wantedEnabled && !loggedFirstBuffer && core.lastCallActive) {
            loggedFirstBuffer = true
            diag("DSP is shaping the audio (first processed buffer after enable)")
        }
    }

    override fun onQueueEndOfStream() {
        // The look-ahead holds back a few ms of audio; it is released from getOutput().
        tailPending = core.pendingFrames > 0
    }

    override fun getOutput(): ByteBuffer {
        if (tailPending && !hasPendingOutput()) {
            tailPending = false
            emitTail()
        }
        return super.getOutput()
    }

    override fun isEnded(): Boolean = super.isEnded() && !tailPending

    override fun onFlush() {
        tailPending = false
        core.reset()
    }

    override fun onReset() {
        tailPending = false
        core.reset()
    }

    private fun emitTail() {
        val fmt = inputAudioFormat
        val ch = fmt.channelCount
        val pending = core.pendingFrames
        if (pending <= 0) return
        val data = FloatArray(pending * ch)
        val written = core.process(data, pending, flushing = true)
        if (written <= 0) return
        val out = replaceOutputBuffer(written * fmt.bytesPerFrame)
        System.arraycopy(data, 0, block, 0, min(data.size, block.size))
        writeSamples(out, written * ch, fmt.encoding == C.ENCODING_PCM_FLOAT, core.lastCallActive)
        out.flip()
    }

    private fun writeSamples(out: ByteBuffer, count: Int, isFloat: Boolean, dither: Boolean) {
        if (isFloat) {
            for (i in 0 until count) out.putFloat(block[i].coerceIn(-1f, 1f))
        } else {
            for (i in 0 until count) {
                var v = block[i] * 32768f
                if (dither) v += nextRand() - nextRand()
                val r = Math.round(v)
                out.putShort((if (r > 32767) 32767 else if (r < -32768) -32768 else r).toShort())
            }
        }
    }

    // xorshift32 -> [0, 1)
    private fun nextRand(): Float {
        var x = rng
        x = x xor (x shl 13)
        x = x xor (x ushr 17)
        x = x xor (x shl 5)
        rng = x
        return (x ushr 8) * (1f / 16777216f)
    }

    private fun diag(message: String) {
        try {
            AurumDiagnosticLog.logEvent(LOG_TAG, message)
        } catch (_: Throwable) {
            // diagnostics must never affect audio
        }
    }
}
