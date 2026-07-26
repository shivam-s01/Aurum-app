package com.aurum.music

import android.content.Context
import androidx.media3.cast.CastPlayer
import androidx.media3.cast.SessionAvailabilityListener
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.CastState
import com.google.android.gms.cast.framework.CastStateListener
import com.google.android.gms.cast.framework.SessionManagerListener

/**
 * Owns everything Chromecast: device/route discovery state, session
 * lifecycle, and the CastPlayer that Media3's cast extension provides —
 * the piece that lets ExoPlayer's Player interface (position, duration,
 * play/pause, queue navigation) work near-identically whether audio is
 * routing locally or to a Cast receiver.
 *
 * ARCHITECTURE: kept as its own class, same reasoning as
 * AurumAudioOutputManager — Cast session/device state has its own
 * lifecycle (CastStateListener, SessionManagerListener,
 * SessionAvailabilityListener) that's orthogonal to local playback/queue
 * state in AurumAudioEngine. AurumAudioEngine owns exactly one concern
 * relevant to this class: which Player (local ExoPlayer vs this
 * CastPlayer) is "active" right now, decided via [isCasting] +
 * [onCastSessionStarted]/[onCastSessionEnded] callbacks.
 *
 * HOW CASTING ACTUALLY WORKS HERE:
 * 1. CastContext discovers Cast devices on the LAN and exposes cast
 *    state (no devices / devices available / connecting / connected)
 *    via CastStateListener — this powers the cast button's icon state
 *    (hidden / outline / connecting spinner / filled+device name),
 *    exactly like Spotify's cast icon behavior.
 * 2. The actual "which device" picker UI is Google's own
 *    MediaRouteButton + MediaRouteChooserDialog (system-provided, not
 *    custom-built) — see MainActivity's showCastDeviceChooser(). This is
 *    deliberate: it's the SAME picker UI users already recognize from
 *    every other Cast app, matches Android's system styling per-OEM, and
 *    Google keeps it current with new device categories automatically.
 *    Reimplementing this as custom Flutter UI would both look
 *    inconsistent with what users expect from "the cast picker" AND
 *    require maintaining device-discovery UI ourselves.
 * 3. Once a session starts, CastPlayer wraps the RemoteMediaClient and
 *    AurumAudioEngine hands off Player-facing calls to it instead of the
 *    local ExoPlayer, loading the current queue as Media3 MediaItems
 *    converted to Cast MediaQueueItems automatically.
 */
@UnstableApi
class AurumCastManager(
    private val context: Context,
) {
    /** High-level state the Dart side needs to render the cast button and
     *  optional "Casting to X" banner — deliberately small/stable like
     *  AudioOutputDeviceKind, so the Flutter icon logic doesn't need to
     *  know CastState's raw int constants. */
    enum class State {
        UNAVAILABLE,   // no Cast devices on this network at all
        AVAILABLE,     // devices found, nothing connected yet
        CONNECTING,
        CONNECTED,
    }

    /** Fires whenever cast state or the connected device's name changes. */
    var onStateChanged: (() -> Unit)? = null

    /** Fires when a Cast session actually becomes ready to receive media —
     *  AurumAudioEngine uses this to hand off playback from local
     *  ExoPlayer to [castPlayer]. */
    var onSessionStarted: (() -> Unit)? = null

    /** Fires when the Cast session ends (user disconnected, device went
     *  away, error) — AurumAudioEngine uses this to hand playback BACK to
     *  local ExoPlayer, resuming from the position CastPlayer was last at. */
    var onSessionEnded: (() -> Unit)? = null

    private val castContext: CastContext? = try {
        CastContext.getSharedInstance(context)
    } catch (e: Exception) {
        // Cast SDK init can fail on devices with no/broken Google Play
        // Services (some Chinese OEM ROMs, Fire OS-style forks). Casting
        // simply isn't available there — same as how Google Sign-In
        // already degrades on those devices elsewhere in this app. Never
        // let this crash app startup.
        null
    }

    /** The Media3 Player that proxies to RemoteMediaClient once a session
     *  is active. Null until castContext is available; AurumAudioEngine
     *  should treat null here identically to "casting unsupported on this
     *  device" (same fallback shape as AudioOutputManager's pre-31 path). */
    val castPlayer: CastPlayer? = castContext?.let { ctx ->
        CastPlayer(ctx).apply {
            setSessionAvailabilityListener(object : SessionAvailabilityListener {
                override fun onCastSessionAvailable() {
                    onSessionStarted?.invoke()
                }
                override fun onCastSessionUnavailable() {
                    onSessionEnded?.invoke()
                }
            })
        }
    }

    private var connectedDeviceName: String? = null

    private val castStateListener = CastStateListener { state ->
        onStateChanged?.invoke()
    }

    private val sessionManagerListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) {
            connectedDeviceName = session.castDevice?.friendlyName
            onStateChanged?.invoke()
        }
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            connectedDeviceName = session.castDevice?.friendlyName
            onStateChanged?.invoke()
        }
        override fun onSessionEnded(session: CastSession, error: Int) {
            connectedDeviceName = null
            onStateChanged?.invoke()
        }
        override fun onSessionStarting(session: CastSession) { onStateChanged?.invoke() }
        override fun onSessionStartFailed(session: CastSession, error: Int) {
            connectedDeviceName = null
            onStateChanged?.invoke()
        }
        override fun onSessionEnding(session: CastSession) {}
        override fun onSessionResuming(session: CastSession, sessionId: String) {}
        override fun onSessionResumeFailed(session: CastSession, error: Int) {
            connectedDeviceName = null
            onStateChanged?.invoke()
        }
        override fun onSessionSuspended(session: CastSession, reason: Int) {
            onStateChanged?.invoke()
        }
    }

    init {
        castContext?.addCastStateListener(castStateListener)
        castContext?.sessionManager?.addSessionManagerListener(
            sessionManagerListener, CastSession::class.java,
        )
    }

    val isCasting: Boolean
        get() = castContext?.sessionManager?.currentCastSession?.isConnected == true

    fun describeState(): Map<String, Any?> {
        val state = when (castContext?.castState) {
            CastState.NO_DEVICES_AVAILABLE, null -> State.UNAVAILABLE
            CastState.NOT_CONNECTED -> State.AVAILABLE
            CastState.CONNECTING -> State.CONNECTING
            CastState.CONNECTED -> State.CONNECTED
            else -> State.UNAVAILABLE
        }
        return mapOf(
            "state" to state.name,
            "deviceName" to connectedDeviceName,
            "supported" to (castContext != null),
        )
    }

    /** Ends the active Cast session. [stopCasting] = true also stops
     *  playback on the receiver (matches the "Stop casting" action in
     *  Spotify's cast sheet); false leaves the receiver playing and just
     *  detaches this app's control of it, matching "Disconnect" there. */
    fun endSession(stopCasting: Boolean) {
        castContext?.sessionManager?.endCurrentSession(stopCasting)
    }

    private val relayServer = AurumCastRelayServer()

    /** Phone's current Wi-Fi LAN IP, e.g. "192.168.1.42" — needed so the
     *  relay URL handed to the Cast receiver actually points at this
     *  phone and not some other interface. Returns null if Wi-Fi isn't
     *  connected (Cast fundamentally requires the phone and receiver on
     *  the same LAN, so casting isn't meaningfully usable without it
     *  anyway — callers should treat null the same as "casting
     *  unavailable right now"). */
    private fun currentLanIp(): String? {
        return try {
            val wifiManager = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? android.net.wifi.WifiManager
            val ipInt = wifiManager?.connectionInfo?.ipAddress ?: return null
            if (ipInt == 0) return null
            String.format(
                "%d.%d.%d.%d",
                ipInt and 0xff,
                ipInt shr 8 and 0xff,
                ipInt shr 16 and 0xff,
                ipInt shr 24 and 0xff,
            )
        } catch (e: Exception) {
            null
        }
    }

    /** Wraps [upstreamUrl] (the real JioSaavn/YouTube CDN URL, which
     *  requires the browser User-Agent below to not be rejected) behind
     *  this phone's local relay server, so the Cast receiver's plain,
     *  header-less GET request succeeds — see AurumCastRelayServer's
     *  class doc for the full why. Returns the original [upstreamUrl]
     *  unchanged if Wi-Fi IP detection or the relay server fails to
     *  start, so a relay hiccup degrades to "may not play on some CDNs"
     *  rather than failing the whole cast attempt outright. */
    fun relayUrlForCast(upstreamUrl: String): String {
        val ip = currentLanIp() ?: return upstreamUrl
        val headers = mapOf(
            "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        )
        return relayServer.buildRelayUrl(ip, upstreamUrl, headers) ?: upstreamUrl
    }

    /** Builds a Cast-friendly MediaItem (artwork URL + metadata as
     *  MediaMetadata) from Aurum's existing song fields — CastPlayer's
     *  Media3→Cast MediaQueueItem conversion reads title/artist/artwork
     *  from here automatically, so no separate Cast-specific metadata
     *  model is needed on the Dart side.
     *
     *  CRITICAL: unlike local ExoPlayer playback, the Cast RECEIVER
     *  device (the TV/Chromecast itself) fetches this URL using its OWN
     *  HTTP client — not the phone's. AurumAudioEngine's local player
     *  sends a browser-style User-Agent on every request specifically
     *  because JioSaavn's CDN and YouTube's googlevideo URLs both
     *  enforce hotlink protection that rejects bare/default HTTP client
     *  requests (see createHttpFactory() in AurumAudioEngine). The Cast
     *  SDK's default media receiver has no supported way to attach a
     *  custom header to that request — so [streamUrl] passed in here
     *  MUST already be the phone-local relay URL from [relayUrlForCast],
     *  not the raw CDN URL, or the receiver will connect but the stream
     *  will fail to actually load. */
    fun buildCastMediaItem(
        mediaId: String,
        streamUrl: String,
        title: String,
        artist: String,
        artworkUrl: String?,
        originalUrlForMimeDetection: String = streamUrl,
    ): MediaItem {
        val metadataBuilder = MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
        if (!artworkUrl.isNullOrEmpty()) {
            metadataBuilder.setArtworkUri(android.net.Uri.parse(artworkUrl))
        }
        return MediaItem.Builder()
            .setMediaId(mediaId)
            .setUri(streamUrl)
            .setMediaMetadata(metadataBuilder.build())
            .setMimeType(mimeTypeFor(originalUrlForMimeDetection))
            .build()
    }

    /** Best-effort MIME type from the URL's extension. Cast receivers are
     *  stricter than local ExoPlayer about knowing the content type up
     *  front (local playback can often sniff/probe it); JioSaavn/YouTube
     *  resolved URLs are consistently audio/mp4 (m4a) or audio/mpeg
     *  (mp3) in this app's fallback chain, so this covers the real
     *  cases without needing a network round-trip just to detect type. */
    private fun mimeTypeFor(url: String): String = when {
        url.contains(".m4a", ignoreCase = true) -> "audio/mp4"
        url.contains(".mp3", ignoreCase = true) -> "audio/mpeg"
        url.contains(".webm", ignoreCase = true) -> "audio/webm"
        else -> "audio/mp4" // safe default — matches the most common resolved format
    }

    fun release() {
        castContext?.removeCastStateListener(castStateListener)
        castContext?.sessionManager?.removeSessionManagerListener(
            sessionManagerListener, CastSession::class.java,
        )
        castPlayer?.setSessionAvailabilityListener(null)
        castPlayer?.release()
        relayServer.stop()
        onStateChanged = null
        onSessionStarted = null
        onSessionEnded = null
    }
}
