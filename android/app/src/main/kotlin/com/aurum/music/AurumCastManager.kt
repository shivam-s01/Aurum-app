package com.aurum.music

import android.content.Context
import androidx.mediarouter.media.MediaRouter
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
 * 2. The "which device" picker is a CUSTOM Flutter bottom sheet backed
 *    by MediaRouter route discovery in this class (see
 *    [startRouteDiscovery]/[selectRoute] below) — NOT Google's
 *    MediaRouteChooserDialog. That dialog requires the hosting Activity
 *    to be AppCompatActivity-based (per Google's own MediaRouter docs);
 *    MainActivity extends FlutterFragmentActivity, which isn't, so the
 *    dialog silently failed to inflate/show (tap did nothing, no
 *    crash/error). Rather than restructure MainActivity's whole Activity
 *    base class — which Flutter's own docs warn against changing
 *    lightly, and which could break other Flutter/plugin assumptions —
 *    driving route discovery straight from MediaRouter and rendering
 *    the list in Flutter avoids the AppCompat dependency entirely.
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

    // CastContext.castState stays stuck at NO_DEVICES_AVAILABLE (which
    // the Dart side reads as "hide the button") until something actually
    // asks MediaRouter to scan — the Cast SDK does NOT start route
    // discovery on its own just because CastContext exists. We register
    // an empty callback here, scoped to the same mergedSelector the
    // picker dialog uses, purely to force discovery so castState
    // reflects real devices on the LAN without the user having to open
    // the picker first.
    //
    // BATTERY FIX (was: registered permanently in init{}, from the
    // moment AurumCastManager was first constructed — which happens the
    // instant ANYTHING touches the lazy `castManager` getter on
    // AurumAudioEngine, including just wiring onSessionStarted/
    // onSessionEnded at app startup, i.e. every single launch, cast
    // never used or not). A permanently-registered MediaRouter callback
    // keeps MediaRouter's discovery machinery (LAN mDNS/SSDP scanning)
    // alive for the manager's entire lifetime, independent of whether
    // any screen showing the cast button is even visible. Measured
    // impact: ~10%/507mAh battery over 24h with only ~1h46m screen-on,
    // ~2h49m background usage — i.e. hours of silent scanning with the
    // app backgrounded and nothing casting.
    //
    // Fix: this callback is now started/stopped in lockstep with
    // CAST_STATE_EVENT_CHANNEL's onListen/onCancel (see
    // AurumEngineChannelHandler) — the same "only run while something
    // is actually listening" discipline already used for
    // pickerScanCallback/startRouteDiscovery below. The cast button is
    // only ever on-screen while that channel has a live Dart listener,
    // so this now scans only while a screen that could show the cast
    // button is actually visible, and stops the moment it isn't —
    // mirroring exactly how AurumMediaSessionService already tears
    // itself down via onTaskRemoved when nothing is playing.
    private val discoveryCallback = object : MediaRouter.Callback() {}
    private var discoveryActive = false

    init {
        castContext?.addCastStateListener(castStateListener)
        castContext?.sessionManager?.addSessionManagerListener(
            sessionManagerListener, CastSession::class.java,
        )
    }

    /** Starts low-intensity discovery so castState/describeState() reflect
     *  real LAN devices — call when a screen with the cast button becomes
     *  visible (CAST_STATE_EVENT_CHANNEL.onListen). Safe to call more than
     *  once; no-ops if already active. */
    fun startCastStateDiscovery() {
        if (discoveryActive) return
        val selector = castContext?.mergedSelector ?: return
        MediaRouter.getInstance(context).addCallback(
            selector,
            discoveryCallback,
            MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY,
        )
        discoveryActive = true
    }

    /** Stops discovery — call when the cast-button screen goes away
     *  (CAST_STATE_EVENT_CHANNEL.onCancel) so scanning doesn't keep
     *  running in the background. */
    fun stopCastStateDiscovery() {
        if (!discoveryActive) return
        MediaRouter.getInstance(context).removeCallback(discoveryCallback)
        discoveryActive = false
    }

    val isCasting: Boolean
        get() = castContext?.sessionManager?.currentCastSession?.isConnected == true

    // ── Custom Cast device picker (route discovery + selection) ──────
    // Fires whenever the available-route list changes while the picker
    // sheet is open, so Dart can render a live-updating list instead of
    // a one-time snapshot — this matters because Cast devices can take
    // a moment to appear on the network after the sheet opens.
    var onRoutesChanged: ((List<Map<String, Any?>>) -> Unit)? = null

    private val router: MediaRouter? = try {
        MediaRouter.getInstance(context)
    } catch (e: Exception) {
        null
    }

    /** Dedicated callback ONLY active while the picker sheet is open —
     *  separate from [discoveryCallback] above (which now only runs while
     *  a screen showing the cast button is visible, via
     *  start/stopCastStateDiscovery, to keep castState accurate for the
     *  button icon without scanning indefinitely). This one uses
     *  CALLBACK_FLAG_PERFORM_ACTIVE_SCAN,
     *  which is more battery-intensive and per Android's own docs should
     *  only be requested while the user is actively picking a device —
     *  hence registering/unregistering it around startRouteDiscovery/
     *  stopRouteDiscovery rather than leaving it on permanently. */
    private val pickerScanCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = emitRoutes()
        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = emitRoutes()
        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = emitRoutes()
    }

    private fun emitRoutes() {
        val r = router ?: return
        val selector = castContext?.mergedSelector ?: return
        val routes = r.routes.filter { route ->
            !route.isDefault && route.matchesSelector(selector) && route.isEnabled
        }
        onRoutesChanged?.invoke(routes.map { route ->
            mapOf(
                "id" to route.id,
                "name" to route.name,
                "description" to route.description,
                "selected" to route.isSelected,
            )
        })
    }

    /** Starts active scanning and immediately emits the current route
     *  snapshot (don't make the picker sheet wait for a change event to
     *  show anything — if devices are already known, show them right
     *  away, then keep updating live as more appear). Call when the
     *  picker sheet opens. */
    fun startRouteDiscovery() {
        val selector = castContext?.mergedSelector ?: run {
            onRoutesChanged?.invoke(emptyList())
            return
        }
        router?.addCallback(
            selector,
            pickerScanCallback,
            MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN or MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY,
        )
        emitRoutes()
    }

    /** Stops active scanning — call when the picker sheet closes, so the
     *  battery-intensive active scan doesn't run indefinitely in the
     *  background after the user is done picking. */
    fun stopRouteDiscovery() {
        router?.removeCallback(pickerScanCallback)
    }

    /** Connects to the route with the given [routeId], starting a Cast
     *  session — this is the manual equivalent of what tapping a device
     *  in MediaRouteChooserDialog does internally, per Google's own docs
     *  on building a custom route picker (SessionManager listens to
     *  MediaRouter's route-selection state, so simply selecting the
     *  route here is enough to kick off the same session lifecycle
     *  [sessionManagerListener] above already handles). Returns false if
     *  the route can no longer be found (e.g. it went away between the
     *  picker showing it and the user tapping it). */
    fun selectRoute(routeId: String): Boolean {
        val r = router ?: return false
        val route = r.routes.firstOrNull { it.id == routeId } ?: return false
        r.selectRoute(route)
        return true
    }

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
        router?.removeCallback(pickerScanCallback)
        stopCastStateDiscovery()
        castPlayer?.setSessionAvailabilityListener(null)
        castPlayer?.release()
        relayServer.stop()
        onStateChanged = null
        onSessionStarted = null
        onSessionEnded = null
        onRoutesChanged = null
    }
}
