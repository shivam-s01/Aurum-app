package com.aurum.music

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Routes resolve() by source:
 *  - "youtube"  -> native YoutubeInnertube (Kotlin -> YouTube, no Worker, no
 *                  MethodChannel round-trip)
 *  - "saavn"/"local" -> unchanged, delegates to MethodChannelStreamResolver
 *                       (direct CDN URLs, no InnerTube needed there)
 *
 * This keeps AurumAudioEngine untouched: it still just calls
 * resolver.resolve(song) / resolver.invalidate(song) same as before.
 */
class HybridStreamResolver(messenger: BinaryMessenger) : StreamResolver {

    companion object {
        private const val TAG = "HybridStreamResolver"
        // Same channel AurumEngineChannelHandler's callbackChannel uses for
        // every other Kotlin -> Dart reverse call (onLikeToggleRequested,
        // etc) — reusing it here means Dart's existing single
        // _handleEngineCallback dispatcher (native_engine_bridge.dart) just
        // gets one more case, no new channel/listener plumbing needed.
        private const val ENGINE_CHANNEL = "com.aurum.music/audio_engine"
    }

    private val fallback = MethodChannelStreamResolver(messenger)
    // FIX ("Auto" quality always shown for YouTube songs in the Bluetooth/
    // output-device sheet and Settings > Player & Audio): YoutubeInnertube
    // .resolve() already computes a real averageBitrate from YouTube's own
    // audio stream formats (see YoutubeInnertube.kt), but this function
    // used to return only `native.url` — the bitrate it had just computed
    // was silently discarded one line below, so AudioPrefs.lastResolvedKbps
    // (which both quality labels read) never had a real YouTube value to
    // fall back from "Auto" to. This channel reports the real number back
    // to Dart the same way the existing Worker/JioSaavn resolve path
    // already does via 'reportResolvedBitrate' in native_engine_bridge.dart
    // — fire-and-forget, matching that call's own "never block the resolve
    // path on a side-channel report" reasoning.
    private val callbackChannel = MethodChannel(messenger, ENGINE_CHANNEL)

    override suspend fun resolve(song: NativeSong, forceRefresh: Boolean): String? {
        if (song.source != "youtube") {
            return fallback.resolve(song, forceRefresh)
        }

        // Native path first: no MethodChannel round-trip, no Worker network
        // hop — fastest path for the vast majority of videos.
        val native = try {
            YoutubeInnertube.resolve(song.id)
        } catch (e: Exception) {
            Log.w(TAG, "Native resolve threw for ${song.id}: ${e.message}")
            null
        }
        if (native?.url != null) {
            // Real YouTube audio bitrate (typically ~128-160kbps Opus/AAC —
            // YouTube never offers a 320kbps audio-only stream the way
            // JioSaavn's fixed '320kbps' field does, so this is genuinely
            // the true ceiling for this source, not a bug). Reported on a
            // best-effort basis: a failure here must never affect playback,
            // it only means the quality label stays on "Auto" for this one
            // song instead of showing the real number.
            callbackChannel.invokeMethod(
                "onYoutubeBitrateResolved",
                mapOf("kbps" to native.bitrate.takeIf { it > 0 }),
            )
            return native.url
        }

        // Fallback: the native extractor can legitimately fail (YouTube
        // page/cipher format changes NewPipeExtractor hasn't patched yet,
        // a transient ContentNotAvailableException that survived its own
        // internal retry, regional blocks the embedded-bypass doesn't
        // clear, etc). Previously there was NO fallback here at all — a
        // native failure meant the song simply never played, which is
        // exactly the "resolve failed" behavior reported. Falling through
        // to the existing Worker-backed Dart resolver keeps the native
        // path as the fast common case while a native failure degrades to
        // the same reliability the app already had before this migration,
        // instead of degrading to "song doesn't play."
        Log.w(TAG, "Native resolve failed for ${song.id} (${YoutubeInnertube.lastFailureReason}), falling back to Worker")
        return fallback.resolve(song, forceRefresh)
    }

    override suspend fun invalidate(song: NativeSong) {
        // Nothing cached natively yet (URLs aren't stored here); still
        // forward so any Dart-side cache for this song is cleared too.
        fallback.invalidate(song)
    }
}
