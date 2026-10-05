package com.aurum.music

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer

/**
 * Media3 AudioProcessor wrapper around [PremiumDspCore] — Premium Sound's
 * in-app DSP. See PremiumDspCore's class comment for why this replaced the
 * platform AudioEffect chain.
 *
 * Sits in DefaultAudioSink's PCM pipeline (installed by AurumAudioEngine's
 * custom RenderersFactory). It is only ever fed decoded PCM; when audio offload
 * or passthrough is active Media3 bypasses all processors, which is why the
 * engine drops offload the moment Premium Sound is switched on.
 *
 * Always "active" for 16-bit / float stereo+mono input so that toggling Premium
 * Sound never needs a sink reconfiguration (that would be an audible gap):
 * while disabled the core is a bit-exact memcpy. Any other PCM layout is
 * reported inactive (NOT_SET) and simply skipped, never an error.
 */
@UnstableApi
class PremiumSoundProcessor : BaseAudioProcessor() {

    private val core = PremiumDspCore()
    private var isFloat = false

    // Format handed to onConfigure() is only *pending* until Media3 calls
    // flush() (same contract as BaseAudioProcessor's own pending/current
    // formats) — buffers of the previous format can still be in flight until
    // then, so the DSP core is only re-targeted in onFlush().
    private var pendingRate = 0
    private var pendingChannels = 0
    private var pendingFloat = false

    /** Thread-safe; takes effect on the next audio buffer with a 200 ms crossfade. */
    fun setParams(enabled: Boolean, intensity: Float, sourceKbps: Int) {
        core.setParams(enabled, intensity, sourceKbps)
    }

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        val encodingOk = inputAudioFormat.encoding == C.ENCODING_PCM_16BIT ||
            inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        val layoutOk = inputAudioFormat.channelCount == 1 || inputAudioFormat.channelCount == 2
        if (!encodingOk || !layoutOk || inputAudioFormat.sampleRate <= 0) {
            pendingRate = 0
            return AudioProcessor.AudioFormat.NOT_SET
        }
        pendingFloat = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT
        pendingRate = inputAudioFormat.sampleRate
        pendingChannels = inputAudioFormat.channelCount
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val out = replaceOutputBuffer(inputBuffer.remaining())
        core.process(inputBuffer, out, isFloat)
        out.flip()
    }

    override fun onFlush() {
        if (pendingRate > 0) {
            isFloat = pendingFloat
            core.configure(pendingRate, pendingChannels) // also clears filter state
        } else {
            core.flush()
        }
    }

    override fun onReset() {
        pendingRate = 0
        pendingChannels = 0
        core.reset()
    }
}
