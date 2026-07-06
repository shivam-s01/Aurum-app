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
 * directly from YouTube's internal player API, no Cloudflare Worker hop.
 *
 * This is a direct port of InnerTune's (actively-maintained, real-world
 * working) resolve chain from its InnerTube.kt / YouTube.kt / YouTubeClient.kt:
 *   1. ANDROID_MUSIC — first-party YT Music client, plain googlevideo URLs,
 *      no cipher. Tried first (also plays age-restricted content).
 *   2. IOS — second attempt if ANDROID_MUSIC fails.
 *   3. TVHTML5_SIMPLY_EMBEDDED_PLAYER + Piped streams — last resort: if even
 *      the embed-bypass player call succeeds (status OK) but we still need
 *      an actual audio URL, fetch it from Piped by matching bitrate, same
 *      as InnerTune does (it does NOT decode signatureCipher itself either —
 *      nobody does this client-side without shipping a JS interpreter).
 *
 * All client names, versions, and API keys below are copied verbatim from
 * InnerTune's source, not guessed.
 */
object YoutubeInnertube {

    private const val TAG = "YoutubeInnertube"
    private const val BASE_URL = "https://music.youtube.com/youtubei/v1/"
    private const val PIPED_STREAMS_URL = "https://pipedapi.kavin.rocks/streams/"

    private val JSON_MEDIA_TYPE = "application/json".toMediaType()

    @Volatile
    var lastFailureReason: String = "unknown"
        private set

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .build()

    private data class YouTubeClient(
        val clientName: String,
        val clientVersion: String,
        val apiKey: String,
        val userAgent: String,
        val osVersion: String? = null,
        val referer: String? = null,
    )

    private const val USER_AGENT_ANDROID =
        "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/65.0.3325.181 Mobile Safari/537.36"
    private const val USER_AGENT_IOS =
        "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)"

    private val ANDROID_MUSIC = YouTubeClient(
        clientName = "ANDROID_MUSIC",
        clientVersion = "5.01",
        apiKey = "AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI",
        userAgent = USER_AGENT_ANDROID,
    )

    private val IOS = YouTubeClient(
        clientName = "IOS",
        clientVersion = "19.29.1",
        apiKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc",
        userAgent = USER_AGENT_IOS,
        osVersion = "17.5.1.21F90",
    )

    private val TVHTML5 = YouTubeClient(
        clientName = "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        clientVersion = "2.0",
        apiKey = "AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8",
        userAgent = "Mozilla/5.0 (PlayStation 4 5.55) AppleWebKit/601.2 (KHTML, like Gecko)",
    )

    data class AudioStream(
        val url: String,
        val itag: Int,
        val bitrate: Long,
        val mimeType: String,
    )

    /**
     * Mirrors InnerTune's YouTube.player(): ANDROID_MUSIC -> IOS -> TVHTML5,
     * and if only TVHTML5 succeeds (meaning the video needed the embed
     * bypass), fetch actual playable URLs from Piped by matching bitrate,
     * because TVHTML5's own adaptiveFormats URLs are signature-ciphered.
     */
    suspend fun resolve(videoId: String): AudioStream? {
        callPlayerSafely(videoId, ANDROID_MUSIC)?.let { json ->
            extractDirectAudio(json, videoId)?.let { return it }
        }

        callPlayerSafely(videoId, IOS)?.let { json ->
            extractDirectAudio(json, videoId)?.let { return it }
        }

        val tvJson = callPlayerSafely(videoId, TVHTML5, embedFallback = true)
        val tvStatus = tvJson?.optJSONObject("playabilityStatus")?.optString("status")
        if (tvStatus != "OK") {
            lastFailureReason = "videoId=$videoId all clients failed, last playabilityStatus=$tvStatus"
            return null
        }

        // TVHTML5 says OK but its URLs are cipher-protected; get real
        // audio URLs from Piped, matched by bitrate (same as InnerTune).
        return try {
            resolveViaPiped(videoId, tvJson)
        } catch (e: Exception) {
            lastFailureReason = "videoId=$videoId Piped fallback failed: ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, lastFailureReason)
            null
        }
    }

    /** Calls player() for one client, swallowing network/parse errors -> null. */
    private suspend fun callPlayerSafely(
        videoId: String,
        ytClient: YouTubeClient,
        embedFallback: Boolean = false,
    ): JSONObject? = try {
        callPlayer(videoId, ytClient, embedFallback)
    } catch (e: Exception) {
        lastFailureReason = "videoId=$videoId ${ytClient.clientName}: ${e.javaClass.simpleName}: ${e.message}"
        Log.w(TAG, "${ytClient.clientName} resolve failed for $videoId: ${e.message}")
        null
    }

    /** Extracts a plain (non-ciphered) audio URL if playabilityStatus is OK. */
    private fun extractDirectAudio(playerJson: JSONObject, videoId: String): AudioStream? {
        val status = playerJson.optJSONObject("playabilityStatus")?.optString("status")
        if (status != "OK") {
            lastFailureReason = "videoId=$videoId playabilityStatus=$status " +
                "reason=${playerJson.optJSONObject("playabilityStatus")?.optString("reason") ?: "none"}"
            return null
        }

        val adaptiveFormats = playerJson.optJSONObject("streamingData")
            ?.optJSONArray("adaptiveFormats") ?: return null

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
            if (itag == 251) return candidate
            if (best == null) best = candidate
        }
        return best
    }

    /** Matches TVHTML5's adaptiveFormats bitrates against Piped's audioStreams. */
    private suspend fun resolveViaPiped(videoId: String, tvJson: JSONObject): AudioStream? {
        val adaptiveFormats = tvJson.optJSONObject("streamingData")
            ?.optJSONArray("adaptiveFormats") ?: return null

        val pipedAudioStreams = fetchPipedStreams(videoId)
        if (pipedAudioStreams.length() == 0) return null

        var best: AudioStream? = null
        for (i in 0 until adaptiveFormats.length()) {
            val fmt = adaptiveFormats.getJSONObject(i)
            val itag = fmt.optInt("itag", -1)
            if (itag != 251 && itag != 140) continue
            val bitrate = fmt.optLong("bitrate", -1L)

            for (j in 0 until pipedAudioStreams.length()) {
                val stream = pipedAudioStreams.getJSONObject(j)
                if (stream.optLong("bitrate", -2L) == bitrate) {
                    val candidate = AudioStream(
                        url = stream.optString("url"),
                        itag = itag,
                        bitrate = bitrate,
                        mimeType = fmt.optString("mimeType", ""),
                    )
                    if (itag == 251) return candidate
                    if (best == null) best = candidate
                    break
                }
            }
        }
        return best
    }

    private suspend fun fetchPipedStreams(videoId: String): org.json.JSONArray =
        suspendCoroutine { cont ->
            val request = Request.Builder()
                .url("$PIPED_STREAMS_URL$videoId")
                .addHeader("Content-Type", "application/json")
                .get()
                .build()

            client.newCall(request).enqueue(object : okhttp3.Callback {
                override fun onFailure(call: okhttp3.Call, e: IOException) {
                    cont.resumeWithException(e)
                }

                override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                    response.use {
                        if (!it.isSuccessful) {
                            cont.resumeWithException(IOException("Piped HTTP ${it.code} for $videoId"))
                            return
                        }
                        val text = it.body?.string()
                        if (text.isNullOrBlank()) {
                            cont.resumeWithException(IOException("Empty Piped response for $videoId"))
                            return
                        }
                        try {
                            val audioStreams = JSONObject(text).optJSONArray("audioStreams")
                                ?: org.json.JSONArray()
                            cont.resume(audioStreams)
                        } catch (e: Exception) {
                            cont.resumeWithException(e)
                        }
                    }
                }
            })
        }

    private suspend fun callPlayer(
        videoId: String,
        ytClient: YouTubeClient,
        embedFallback: Boolean = false,
    ): JSONObject = suspendCoroutine { cont ->
        val clientJson = JSONObject().apply {
            put("clientName", ytClient.clientName)
            put("clientVersion", ytClient.clientVersion)
            put("hl", "en")
            put("gl", "US")
            put("visitorData", "CgtsZG1ySnZiQWtSbyiMjuGSBg%3D%3D")
            ytClient.osVersion?.let { put("osVersion", it) }
        }

        val contextJson = JSONObject().apply {
            put("client", clientJson)
            if (embedFallback) {
                put("thirdParty", JSONObject().apply {
                    put("embedUrl", "https://www.youtube.com/watch?v=$videoId")
                })
            }
        }

        val bodyJson = JSONObject().apply {
            put("context", contextJson)
            put("videoId", videoId)
            put("contentCheckOk", true)
        }

        val requestBuilder = Request.Builder()
            .url(BASE_URL + "player?key=${ytClient.apiKey}&prettyPrint=false")
            .addHeader("Content-Type", "application/json")
            .addHeader("X-Goog-Api-Format-Version", "1")
            .addHeader("X-YouTube-Client-Name", ytClient.clientName)
            .addHeader("X-YouTube-Client-Version", ytClient.clientVersion)
            .addHeader("x-origin", "https://music.youtube.com")
            .addHeader("User-Agent", ytClient.userAgent)
        ytClient.referer?.let { requestBuilder.addHeader("Referer", it) }
        val request = requestBuilder
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
