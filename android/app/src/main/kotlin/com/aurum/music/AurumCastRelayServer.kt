package com.aurum.music

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedOutputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * THE fix for "Chromecast connects fine but audio never plays / spins
 * forever buffering": a Cast RECEIVER device (the TV/Chromecast dongle
 * itself, not the phone) fetches the stream URL using its OWN HTTP
 * client. JioSaavn's CDN and YouTube's googlevideo URLs both enforce
 * hotlink protection that only accepts requests carrying a real
 * browser-style User-Agent — see AurumAudioEngine.createHttpFactory(),
 * which is exactly why local playback already sets one. The Cast SDK
 * has no supported way to attach custom per-stream HTTP headers to a
 * MediaInfo/MediaQueueItem sent to the DEFAULT media receiver (only DRM
 * license requests support custom headers) — so without this proxy, the
 * receiver's bare request gets rejected by the CDN, and the user sees
 * "Connected to [TV]" with nothing audible: it connects, but silently
 * never actually plays.
 *
 * HOW THIS FIXES IT: runs a tiny local HTTP server ON THE PHONE, bound
 * to its LAN IP (the Cast receiver and phone are always on the same
 * Wi-Fi network for local/default-receiver casting — Google Cast simply
 * doesn't work across networks). Cast is given a URL pointing at the
 * PHONE (e.g. http://192.168.1.42:41823/stream/<token>) instead of the
 * CDN directly. When the receiver requests that URL, this server
 * fetches the real CDN URL itself — WITH the correct headers, exactly
 * like local ExoPlayer playback already does — and streams the response
 * bytes straight through. From the CDN's perspective, the request looks
 * identical to the one that already works for local playback, because
 * it IS that same request, just relayed. From the receiver's
 * perspective, it's a plain HTTP GET with a normal audio response —
 * no special headers required on its end at all.
 *
 * This is the same "local relay" pattern used by Kodi, VLC, and other
 * Android apps that cast from sources requiring auth/headers the
 * default Cast receiver can't attach itself.
 */
class AurumCastRelayServer {
    companion object {
        private const val TAG = "AurumCastRelay"
        private const val PORT_RANGE_START = 41800
        private const val PORT_RANGE_TRIES = 20
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(java.time.Duration.ofSeconds(16))
        .readTimeout(java.time.Duration.ofSeconds(20))
        .build()

    // Maps a short-lived token -> (real upstream URL, headers to send
    // upstream). Tokens (not raw URLs) are used in the path so a URL
    // containing its own query params/special characters never has to
    // round-trip through URL-encoding into another URL's path segment.
    private val registry = ConcurrentHashMap<String, RelayTarget>()
    private val tokenCounter = AtomicInteger(0)

    private data class RelayTarget(val upstreamUrl: String, val headers: Map<String, String>)

    private var serverSocket: ServerSocket? = null
    private val scope = CoroutineScope(Dispatchers.IO + Job())
    @Volatile private var acceptLoopJob: Job? = null
    @Volatile private var boundPort: Int = -1

    /** Starts the local server if not already running, binding to the
     *  first free port in range. Idempotent — safe to call every time a
     *  Cast session starts. */
    @Synchronized
    fun ensureStarted(): Boolean {
        if (serverSocket != null && serverSocket?.isClosed == false) return true
        for (attempt in 0 until PORT_RANGE_TRIES) {
            val port = PORT_RANGE_START + attempt
            try {
                val socket = ServerSocket()
                socket.reuseAddress = true
                // Binding to 0.0.0.0 (all interfaces) rather than just the
                // Wi-Fi IP: on some devices the Wi-Fi interface address
                // isn't trivially queryable at bind time, and 0.0.0.0 is
                // reachable from the LAN either way — the receiver only
                // ever sees whichever IP we hand it in the URL (see
                // buildRelayUrl), so binding broadly here is harmless.
                socket.bind(InetSocketAddress("0.0.0.0", port))
                serverSocket = socket
                boundPort = port
                acceptLoopJob = scope.launch { acceptLoop(socket) }
                Log.d(TAG, "Cast relay listening on port $port")
                return true
            } catch (e: Exception) {
                // Port in use — try the next one in range.
            }
        }
        Log.w(TAG, "Could not bind cast relay server to any port in range")
        return false
    }

    private suspend fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val incoming: Socket = try {
                socket.accept()
            } catch (e: Exception) {
                break // socket closed from stop() — normal shutdown path
            }
            scope.launch { handleConnection(incoming) }
        }
    }

    private fun handleConnection(client: Socket) {
        client.use { sock ->
            try {
                sock.soTimeout = 20_000
                val input = sock.getInputStream().bufferedReader(Charsets.ISO_8859_1)
                val requestLine = input.readLine() ?: return
                // Read remaining request headers — we mostly don't need
                // them, EXCEPT Range, which Cast receivers send when the
                // user seeks. Without forwarding it upstream, every seek
                // would re-download from byte 0, which reads as a stall/
                // stutter on seek rather than an instant jump.
                var rangeHeader: String? = null
                while (true) {
                    val line = input.readLine() ?: break
                    if (line.isEmpty()) break
                    if (line.startsWith("Range:", ignoreCase = true)) {
                        rangeHeader = line.substringAfter(":").trim()
                    }
                }
                // Request line looks like: "GET /stream/<token> HTTP/1.1"
                val parts = requestLine.split(" ")
                if (parts.size < 2) { writeSimpleError(sock, 400); return }
                val path = parts[1]
                val token = path.removePrefix("/stream/").substringBefore('?')
                val target = registry[token]
                if (target == null) { writeSimpleError(sock, 404); return }

                relayFromUpstream(sock, target, rangeHeader)
            } catch (e: Exception) {
                Log.w(TAG, "Relay connection error: ${e.message}")
            }
        }
    }

    private fun relayFromUpstream(clientSocket: Socket, target: RelayTarget, rangeHeader: String?) {
        val requestBuilder = Request.Builder().url(target.upstreamUrl)
        target.headers.forEach { (k, v) -> requestBuilder.header(k, v) }
        // Forward the receiver's Range request upstream unchanged — the
        // CDN handles the actual byte-range slicing, we just relay
        // whatever it sends back (200+full-body or 206+partial-body)
        // through to the receiver as-is.
        if (rangeHeader != null) requestBuilder.header("Range", rangeHeader)
        val request = requestBuilder.build()

        client.newCall(request).execute().use { response ->
            val out: OutputStream = BufferedOutputStream(clientSocket.getOutputStream())
            val body = response.body
            val contentType = body?.contentType()?.toString() ?: "audio/mp4"
            val contentLength = body?.contentLength() ?: -1L
            val isPartial = response.code == 206
            val contentRange = response.header("Content-Range")

            val headerBuilder = StringBuilder()
            headerBuilder.append(if (isPartial) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
            headerBuilder.append("Content-Type: $contentType\r\n")
            if (contentLength >= 0) headerBuilder.append("Content-Length: $contentLength\r\n")
            if (isPartial && contentRange != null) headerBuilder.append("Content-Range: $contentRange\r\n")
            headerBuilder.append("Connection: close\r\n")
            headerBuilder.append("Accept-Ranges: bytes\r\n")
            headerBuilder.append("\r\n")
            out.write(headerBuilder.toString().toByteArray(Charsets.ISO_8859_1))

            body?.byteStream()?.use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read == -1) break
                    out.write(buffer, 0, read)
                }
            }
            out.flush()
        }
    }

    private fun writeSimpleError(sock: Socket, code: Int) {
        try {
            val msg = "HTTP/1.1 $code Error\r\nConnection: close\r\n\r\n"
            sock.getOutputStream().write(msg.toByteArray(Charsets.ISO_8859_1))
        } catch (e: Exception) { /* client already gone — nothing to do */ }
    }

    /** Registers [upstreamUrl] (the real, header-requiring CDN URL) and
     *  returns a phone-local URL the Cast receiver can fetch instead.
     *  [localIp] should be the phone's current Wi-Fi LAN IP (e.g.
     *  "192.168.1.42") — the SAME network the Cast device is on. */
    fun buildRelayUrl(localIp: String, upstreamUrl: String, headers: Map<String, String>): String? {
        if (!ensureStarted()) return null
        val token = "t${tokenCounter.incrementAndGet()}_${System.currentTimeMillis()}"
        registry[token] = RelayTarget(upstreamUrl, headers)
        // Cap registry size defensively — a long queue shouldn't leak
        // unbounded entries across a long cast session.
        if (registry.size > 200) {
            registry.keys.take(registry.size - 200).forEach { registry.remove(it) }
        }
        return "http://$localIp:$boundPort/stream/$token"
    }

    fun stop() {
        acceptLoopJob?.cancel()
        try { serverSocket?.close() } catch (e: Exception) { }
        serverSocket = null
        registry.clear()
    }
}
