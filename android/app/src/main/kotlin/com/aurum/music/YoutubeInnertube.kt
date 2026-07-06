package com.aurum.music

import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * Native Kotlin InnerTube client — resolves a playable audio stream URL
 * directly from YouTube's internal player API, with no external proxy or
 * Cloudflare Worker hop. Modelled on ViMusic's innertube module, adapted to
 * plain OkHttp + org.json (no Ktor/kotlinx.serialization, to keep the
 * dependency footprint identical to the rest of the engine).
 *
 * Chain: Kotlin -> music.youtube.com/youtubei/v1/player -> googlevideo URL.
 * Falls back to TVHTML5_SIMPLY_EMBEDDED_PLAYER context (age/region-blocked
 * cases) same as the old Worker's ANDROID_VR -> embedded fallback did.
 */
object YoutubeInnertube {

    private const val TAG = "YoutubeInnertube"
    private const val HOST = "https://music.youtube.com"
    private const val PLAYER_ENDPOINT = "$HOST/youtubei/v1/player"
    private const val API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    // Set on every failed resolve attempt so callers (HybridStreamResolver)
    // can surface the real cause in the on-screen error banner, without
    // needing adb/Logcat to diagnose. Always reflects the LAST attempt.
    @Volatile
    var lastFailureReason: String = "unknown"
        private set

    private val JSON_MEDIA_TYPE = "application/json".toMediaType()

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    private data class ClientContext(
        val clientName: String,
        val clientVersion: String,
        val platform: String,
        val androidSdkVersion: Int? = null,
        val userAgent: String? = null,
        val visitorData: String = "CgtEUlRINDFjdm1YayjX1pSaBg%3D%3D",
    )

    private val ANDROID_MUSIC = ClientContext(
        clientName = "ANDROID_MUSIC",
        clientVersion = "6.51.53",
        platform = "MOBILE",
        androidSdkVersion = 30,
        userAgent = "com.google.android.apps.youtube.music/6.51.53 (Linux; U; Android 11) gzip",
    )

    private val TVHTML5_EMBED = ClientContext(
        clientName = "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        clientVersion = "2.0",
        platform = "TV",
    )

    data class AudioStream(
        val url: String,
        val itag: Int,
        val bitrate: Long,
        val mimeType: String,
    )

    /**
     * Resolves [videoId] to the best available audio-only stream URL.
     * Returns null if every attempt (primary + fallback) fails, so the
     * caller (HybridStreamResolver) can decide what to do next — same
     * contract as the old MethodChannel resolver.
     */
    suspend fun resolve(videoId: String): AudioStream? {
        try {
            selectBestAudio(callPlayer(videoId, ANDROID_MUSIC))?.let { return it }
        } catch (e: Exception) {
            lastFailureReason = "ANDROID_MUSIC: ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "ANDROID_MUSIC resolve failed for $videoId: ${e.message}")
        }

        try {
            selectBestAudio(callPlayer(videoId, TVHTML5_EMBED, embedFallback = true))?.let { return it }
        } catch (e: Exception) {
            lastFailureReason = "TVHTML5_EMBED: ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "TVHTML5_SIMPLY_EMBEDDED_PLAYER resolve failed for $videoId: ${e.message}")
        }

        return null
    }

    private fun selectBestAudio(playerJson: JSONObject?): AudioStream? {
        val playabilityStatus = playerJson?.optJSONObject("playabilityStatus")
        val status = playabilityStatus?.optString("status")
        if (status != "OK") {
            val reason = playabilityStatus?.optString("reason") ?: "no playabilityStatus in response"
            lastFailureReason = "playabilityStatus=$status reason=$reason"
            Log.w(TAG, lastFailureReason)
            return null
        }

        val adaptiveFormats = playerJson.optJSONObject("streamingData")
            ?.optJSONArray("adaptiveFormats")
        if (adaptiveFormats == null) {
            lastFailureReason = "status OK but no adaptiveFormats in streamingData"
            Log.w(TAG, lastFailureReason)
            return null
        }

        // Prefer itag 251 (Opus, best quality), fall back to 140 (AAC).
        var best: AudioStream? = null
        for (i in 0 until adaptiveFormats.length()) {
            val fmt = adaptiveFormats.getJSONObject(i)
            val itag = fmt.optInt("itag", -1)
            if (itag != 251 && itag != 140) continue
            val url = fmt.optString("url", "").takeIf { it.isNotBlank() } ?: continue

            val candidate = AudioStream(
                url = url,
                itag = itag,
                bitrate = fmt.optLong("bitrate", 0L),
                mimeType = fmt.optString("mimeType", ""),
            )
            // itag 251 wins outright if present.
            if (itag == 251) return candidate
            if (best == null) best = candidate
        }
        return best
    }

    private suspend fun callPlayer(
        videoId: String,
        context: ClientContext,
        embedFallback: Boolean = false,
    ): JSONObject = suspendCoroutine { cont ->
        val contextJson = JSONObject().apply {
            put("client", JSONObject().apply {
                put("clientName", context.clientName)
                put("clientVersion", context.clientVersion)
                put("platform", context.platform)
                put("hl", "en")
                put("visitorData", context.visitorData)
                context.androidSdkVersion?.let { put("androidSdkVersion", it) }
                context.userAgent?.let { put("userAgent", it) }
            })
            if (embedFallback) {
                put("thirdParty", JSONObject().apply {
                    put("embedUrl", "https://www.youtube.com/watch?v=$videoId")
                })
            }
        }

        val bodyJson = JSONObject().apply {
            put("context", contextJson)
            put("videoId", videoId)
        }

        val request = Request.Builder()
            .url("$PLAYER_ENDPOINT?prettyPrint=false")
            .addHeader("Content-Type", "application/json")
            .addHeader("X-Goog-Api-Key", API_KEY)
            .addHeader(
                "X-Goog-FieldMask",
                "playabilityStatus.status,streamingData.adaptiveFormats,videoDetails.videoId"
            )
            .addHeader("User-Agent", context.userAgent ?: "Mozilla/5.0")
            .post(bodyJson.toString().toRequestBody(JSON_MEDIA_TYPE))
            .build()

        client.newCall(request).enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, e: IOException) {
                cont.resumeWithException(e)
            }

            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                response.use {
                    if (!it.isSuccessful) {
                        cont.resumeWithException(IOException("HTTP ${it.code} for videoId=$videoId"))
                        return
                    }
                    val text = it.body?.string()
                    if (text.isNullOrBlank()) {
                        cont.resumeWithException(IOException("Empty player response for videoId=$videoId"))
                        return
                    }
                    try {
                        cont.resume(JSONObject(text))
                    } catch (e: Exception) {
                        cont.resumeWithException(e)
                    }
                }
            }
        })
    }
}
