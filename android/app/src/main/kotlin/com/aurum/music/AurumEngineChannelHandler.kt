package com.aurum.music

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AurumEngineChannelHandler(context: Context, messenger: BinaryMessenger) {

    // Kept as an application-context field — the constructor parameter
    // itself isn't visible from the method-call handler defined later in
    // this class, and Auto Sleep Guard's methods (below) need a Context.
    private val appContext: Context = context.applicationContext

    companion object {
        private const val METHOD_CHANNEL = "com.aurum.music/audio_engine"
        private const val EVENT_CHANNEL = "com.aurum.music/audio_engine_state"
        private const val ERROR_CHANNEL = "com.aurum.music/audio_engine_errors"
        private const val OUTPUT_DEVICES_EVENT_CHANNEL = "com.aurum.music/audio_output_devices"
        private const val CAST_STATE_EVENT_CHANNEL = "com.aurum.music/cast_state"
        private const val CAST_ROUTES_EVENT_CHANNEL = "com.aurum.music/cast_routes"
    }

    private val resolver = HybridStreamResolver(messenger)
    val engine: AurumAudioEngine = AurumMediaSessionService.sharedEngine
        ?: AurumAudioEngine(context.applicationContext, resolver)
    private val scope = CoroutineScope(Dispatchers.Main.immediate)
    private var stateJob: Job? = null
    private var errorSink: EventChannel.EventSink? = null
    private val callbackChannel = MethodChannel(messenger, METHOD_CHANNEL)

    init {
        // Publish the engine BEFORE the service can possibly start, so
        // AurumMediaSessionService.onCreate() always finds a non-null
        // sharedEngine (see the defensive stopSelf() fallback there).
        AurumMediaSessionService.sharedEngine = engine

        engine.onPlaybackError = { message, silent ->
            errorSink?.success(mapOf("message" to message, "silent" to silent))
        }
        // NOTE: we do NOT manually call startForegroundService() here.
        //
        // Media3's MediaSessionService promotes itself to a foreground
        // service automatically — internally, whenever the MediaSession's
        // player starts actually playing, MediaSessionService calls
        // startForeground() itself via its MediaNotificationManager,
        // using the notification built from the player's current
        // MediaMetadata (see AurumMediaSessionService, which does not
        // override onUpdateNotification — that's what leaves this default
        // behavior in place).
        //
        // The PREVIOUS version of this code called
        // ContextCompat.startForegroundService(...) manually on every
        // queue change, racing Media3's own foreground promotion: Android
        // requires startForeground() within ~5s of startForegroundService()
        // being called, but a manual call here could fire before playback
        // (and therefore Media3's own notification) was actually ready,
        // producing an intermittent
        // android.app.ForegroundServiceDidNotStartInTimeException crash —
        // exactly the "keeps stopping" / no background playback / no lock
        // screen controls symptom this fixes. Removing the manual call
        // lets Media3 own the entire foreground lifecycle, which is the
        // documented/supported pattern.
        engine.onQueueChanged = { /* no-op — Media3 handles foreground promotion internally */ }

        // Reverse channel: notification/lock-screen heart tap → Dart's
        // FavoritesProvider.toggleFavorite(). Dart is expected to call
        // setCurrentSongLiked() back once the toggle completes so the icon
        // reflects the authoritative (persisted) state rather than an
        // optimistic native-side flip.
        engine.onLikeToggleRequested = { songId ->
            callbackChannel.invokeMethod("onLikeToggleRequested", mapOf("songId" to songId))
        }

        callbackChannel.setMethodCallHandler(::onMethodCall)

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                stateJob = scope.launch {
                    engine.state.collect { s ->
                        sink.success(
                            mapOf(
                                "processingState" to s.processingState,
                                "playing" to s.playing,
                                "positionMs" to s.positionMs,
                                "bufferedPositionMs" to s.bufferedPositionMs,
                                "durationMs" to s.durationMs,
                                "currentIndex" to s.currentIndex,
                                "speed" to s.speed,
                                "queueIds" to s.queueIds,
                                "currentSongId" to s.currentSongId,
                                "liked" to s.liked,
                            )
                        )
                    }
                }
            }
            override fun onCancel(args: Any?) { stateJob?.cancel(); stateJob = null }
        })

        EventChannel(messenger, ERROR_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) { errorSink = sink }
            override fun onCancel(args: Any?) { errorSink = null }
        })

        // Live audio-output-device-list updates (Bluetooth connect/
        // disconnect, wired headset plug/unplug) so the picker sheet
        // updates itself without the user closing and reopening it.
        EventChannel(messenger, OUTPUT_DEVICES_EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                engine.outputManager.onDevicesChanged = {
                    sink.success(mapOf(
                        "devices" to engine.outputManager.describeDevices(),
                        "supportsExplicitRouting" to engine.outputManager.supportsExplicitRouting(),
                    ))
                }
            }
            override fun onCancel(args: Any?) {
                engine.outputManager.onDevicesChanged = null
            }
        })

        // ── Chromecast: state stream + session handoff ──────────────
        // onStateChanged covers device-available/connecting/connected
        // transitions (drives the cast button's icon). The actual
        // playback handoff (local <-> CastPlayer) happens in
        // onSessionStarted/onSessionEnded below, which fire specifically
        // when a session becomes ready to receive media / stops being
        // able to, per Media3's SessionAvailabilityListener contract.
        EventChannel(messenger, CAST_STATE_EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                engine.castManager.onStateChanged = {
                    sink.success(engine.castManager.describeState())
                }
                sink.success(engine.castManager.describeState())
            }
            override fun onCancel(args: Any?) {
                engine.castManager.onStateChanged = null
            }
        })

        // Custom Cast device picker's live route list — onListen/onCancel
        // double as "picker sheet opened/closed" signals, starting and
        // stopping the battery-costlier active scan exactly while the
        // sheet is actually visible (see AurumCastManager.startRouteDiscovery's
        // doc for why active scan shouldn't run all the time).
        EventChannel(messenger, CAST_ROUTES_EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                engine.castManager.onRoutesChanged = { routes ->
                    sink.success(routes)
                }
                engine.castManager.startRouteDiscovery()
            }
            override fun onCancel(args: Any?) {
                engine.castManager.onRoutesChanged = null
                engine.castManager.stopRouteDiscovery()
            }
        })

        var castHandoffGeneration = 0

        engine.castManager.onSessionStarted = {
            val myGeneration = ++castHandoffGeneration
            val cp = engine.castManager.castPlayer
            if (cp != null) {
                scope.launch {
                    // Resolve the FULL queue (not just the songs local
                    // ExoPlayer had already loaded) before handing off —
                    // otherwise skipping to a song CastPlayer's own
                    // internal queue navigation reaches, but that was
                    // never resolved on the phone, would have no stream
                    // URL at all and silently fail to play once cast
                    // gets there. This mirrors how local playback lazily
                    // resolves ahead-of-time via maybeAutoExtendQueue,
                    // just done eagerly here since CastPlayer can't call
                    // back into Dart/HybridStreamResolver itself.
                    val fullQueue = engine.currentFullQueueForCast(resolver)
                    // Guard against a slow resolve (many songs / slow
                    // network) landing after the user has already
                    // disconnected or started a NEW cast session in the
                    // meantime — applying a stale queue snapshot at that
                    // point would incorrectly restart/hijack whatever is
                    // playing now.
                    if (myGeneration != castHandoffGeneration) return@launch
                    val startIndex = engine.currentCastStartIndexInFullQueue()
                    val startPositionMs = engine.currentLocalPositionMs()
                    if (fullQueue.isNotEmpty()) {
                        val mediaItems = fullQueue.map { (song, url) ->
                            // Relay every URL through the phone's local
                            // server first — see AurumCastManager.relayUrlForCast
                            // and AurumCastRelayServer's class doc for why this
                            // is required (Cast receivers can't attach the
                            // browser User-Agent JioSaavn/YouTube CDNs need).
                            val relayedUrl = engine.castManager.relayUrlForCast(url)
                            engine.castManager.buildCastMediaItem(
                                mediaId = song.id,
                                streamUrl = relayedUrl,
                                title = song.title,
                                artist = song.artist,
                                artworkUrl = song.artworkUrl.ifEmpty { null },
                                originalUrlForMimeDetection = url,
                            )
                        }
                        if (myGeneration != castHandoffGeneration) return@launch
                        cp.setMediaItems(mediaItems, startIndex.coerceIn(0, mediaItems.size - 1), startPositionMs)
                        cp.prepare()
                        cp.play()
                    }
                }
                // Silence local playback now that the receiver has the
                // queue — leaves position/queue state intact so ending
                // the cast session can resume locally without a stutter.
                engine.pauseLocalForCastHandoff()
            }
            engine.refreshState()
        }

        engine.castManager.onSessionEnded = {
            ++castHandoffGeneration // invalidates any in-flight resolve from onSessionStarted above
            // Copy the receiver's last known position back onto the local
            // player before resuming, so ending a cast session (device
            // turned off, user tapped disconnect, wifi drop) hands back
            // to the phone at the same spot rather than wherever local
            // playback happened to be paused at — this is the
            // "seamless" half of the handoff, matching how Spotify/YT
            // Music resume locally when a cast session drops.
            val lastCastPositionMs = engine.castManager.castPlayer?.currentPosition
            if (lastCastPositionMs != null && lastCastPositionMs > 0) {
                engine.seek(lastCastPositionMs)
            }
            engine.play()
            engine.refreshState()
        }
    }

    private fun parseSong(map: Map<*, *>): NativeSong = NativeSong(
        id = map["id"] as String,
        title = map["title"] as? String ?: "",
        artist = map["artist"] as? String ?: "",
        album = map["album"] as? String ?: "",
        artworkUrl = map["artworkUrl"] as? String ?: "",
        source = map["source"] as? String ?: "saavn",
        isLocal = map["isLocal"] as? Boolean ?: false,
        localPath = map["localPath"] as? String,
    )

    @Suppress("UNCHECKED_CAST")
    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "playQueue" -> {
                    val songs = (call.argument<List<Map<String, Any?>>>("songs") ?: emptyList()).map(::parseSong)
                    val startIndex = call.argument<Int>("startIndex") ?: 0
                    engine.playQueue(songs, startIndex)
                    result.success(null)
                }
                // FIX ("UI stuck showing isLoading=true / isPlaying=false
                // while audio genuinely plays in background"): engine.
                // refreshState() already existed (used internally for cast
                // handoff, see onSessionStarted/onSessionEnded above) but
                // was never reachable from Dart — there was no MethodChannel
                // case for it at all. That meant the Dart-side resync call
                // (PlayerProvider.didChangeAppLifecycleState /
                // _loadingWatchdog) had nothing real to invoke and could
                // only guess-and-clear the stuck flag locally, never
                // actually re-reading ExoPlayer's true current state. If a
                // Player.Listener callback (onIsPlayingChanged/
                // onPlaybackStateChanged) is ever coalesced or dropped by
                // ExoPlayer internally — ExoPlayer really is playing, it
                // just never re-fired the callback that triggers pushState()
                // — this is the only way to recover without waiting for
                // the next natural transition (next song, seek, etc). This
                // just re-reads activePlayer's live fields and re-emits a
                // NativeEngineState immediately; it is not a resolve/replay,
                // so it's safe to call at any time, repeatedly.
                "refreshState" -> {
                    engine.refreshState()
                    result.success(null)
                }
                "playSong" -> {
                    engine.playSong(parseSong(call.argument<Map<String, Any?>>("song")!!))
                    result.success(null)
                }
                "addToQueue" -> {
                    // FIX: previously fired engine.addToQueue() (a plain
                    // fun launching its own unawaited coroutine) and
                    // returned success immediately — Dart's `await`
                    // resolved before the native media-item list actually
                    // updated. addToQueue is now suspend + queueMutex-
                    // serialized (see AurumAudioEngine); calling it here
                    // inside scope.launch and only replying success AFTER
                    // it completes means Dart's await genuinely waits for
                    // the native queue to be in its final state — closing
                    // the race that let a fast-following moveQueueItem
                    // (playNext()) desync queueSongs from the real player.
                    val song = parseSong(call.argument<Map<String, Any?>>("song")!!)
                    scope.launch {
                        engine.addToQueue(song)
                        result.success(null)
                    }
                }
                "removeFromQueue" -> {
                    val index = call.argument<Int>("index") ?: -1
                    scope.launch {
                        engine.removeFromQueue(index)
                        result.success(null)
                    }
                }
                "moveQueueItem" -> {
                    val from = call.argument<Int>("from") ?: 0
                    val to = call.argument<Int>("to") ?: 0
                    scope.launch {
                        engine.moveQueueItem(from, to)
                        result.success(null)
                    }
                }
                "clearQueue" -> { engine.clearQueue(); result.success(null) }
                "play" -> { engine.play(); result.success(null) }
                "pause" -> { engine.pause(); result.success(null) }
                "stop" -> { engine.stop(); result.success(null) }
                "seek" -> {
                    engine.seek((call.argument<Number>("positionMs") ?: 0).toLong())
                    result.success(null)
                }
                "skipToNext" -> { engine.skipToNext(); result.success(null) }
                "skipToPrevious" -> { engine.skipToPrevious(); result.success(null) }
                "skipToQueueItem" -> {
                    engine.skipToQueueItem(call.argument<Int>("index") ?: 0)
                    result.success(null)
                }
                "setRepeatMode" -> {
                    engine.setRepeatMode(call.argument<String>("mode") ?: "none")
                    result.success(null)
                }
                "setShuffleMode" -> {
                    engine.setShuffleMode(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "setSpeed" -> {
                    engine.setSpeed((call.argument<Number>("speed") ?: 1.0).toFloat())
                    result.success(null)
                }
                "setCurrentSongLiked" -> {
                    engine.setCurrentSongLiked(call.argument<Boolean>("liked") ?: false)
                    AurumMediaSessionService.instance?.onLikedStateChanged()
                    result.success(null)
                }
                "setCrossfadeSeconds" -> {
                    engine.setCrossfadeSeconds(call.argument<Double>("seconds") ?: 0.0)
                    result.success(null)
                }
                "sleepAfterCurrentSong" -> { engine.sleepAfterCurrentSong(); result.success(null) }
                "sleepFadeOutAndPause" -> {
                    val fadeMs = (call.argument<Number>("fadeMs") ?: 8000).toLong()
                    engine.sleepFadeOutAndPause(fadeMs)
                    result.success(null)
                }
                "applyAudioEffects" -> {
                    val bassBoost = call.argument<Boolean>("bassBoost") ?: false
                    val volNorm = call.argument<Boolean>("volumeNormalization") ?: false
                    // Dart sends gains already converted to millibels (see
                    // NativeAudioEngine.applyAudioEffects — dB * 100).
                    @Suppress("UNCHECKED_CAST")
                    val bandGainsMb = (call.argument<List<Any>>("bandGainsMb"))
                        ?.map { (it as Number).toInt() }
                    engine.effects.applySettings(bassBoost, volNorm, bandGainsMb)
                    result.success(null)
                }
                "getEqualizerBands" -> {
                    result.success(engine.effects.describeBands())
                }
                "applyPremiumSound" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    engine.effects.applyPremiumSound(enabled)
                    result.success(null)
                }
                "reportResolvedBitrate" -> {
                    val kbps = call.argument<Int>("kbps")
                    engine.effects.reportSourceBitrate(kbps)
                    result.success(null)
                }
                "getPremiumSoundCapabilities" -> {
                    result.success(engine.effects.describeCapabilities())
                }
                // ── Audio output device picker ──────────────────────────
                "getAudioOutputDevices" -> {
                    result.success(mapOf(
                        "devices" to engine.outputManager.describeDevices(),
                        "supportsExplicitRouting" to engine.outputManager.supportsExplicitRouting(),
                    ))
                }
                "selectAudioOutputDevice" -> {
                    val deviceId = call.argument<Int>("deviceId")
                    if (deviceId == null) {
                        result.error("BAD_ARGS", "deviceId required", null)
                        return@onMethodCall
                    }
                    if (!engine.outputManager.supportsExplicitRouting()) {
                        // Pre-API 31: no explicit per-device routing exists.
                        // Returning false (not an error) lets Dart show its
                        // "routing is automatic on this Android version"
                        // messaging instead of a scary failure.
                        result.success(false)
                        return@onMethodCall
                    }
                    val ok = engine.outputManager.selectDevice(deviceId)
                    result.success(ok)
                }
                "setForceSpeaker" -> {
                    val force = call.argument<Boolean>("force") ?: false
                    engine.outputManager.setForceSpeaker(force)
                    result.success(null)
                }
                // ── Chromecast ───────────────────────────────────────────
                "getCastState" -> {
                    result.success(engine.castManager.describeState())
                }
                "endCastSession" -> {
                    val stopCasting = call.argument<Boolean>("stopCasting") ?: false
                    engine.castManager.endSession(stopCasting)
                    result.success(null)
                }
                "selectCastRoute" -> {
                    val routeId = call.argument<String>("routeId")
                    if (routeId == null) {
                        result.success(false)
                    } else {
                        result.success(engine.castManager.selectRoute(routeId))
                    }
                }
                "setPremiumSoundCompare" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    engine.effects.setPremiumSoundCompare(enabled)
                    result.success(null)
                }
                "exitPremiumSoundCompare" -> {
                    engine.effects.exitPremiumSoundCompare()
                    result.success(null)
                }
                // FIX (2026-07-07) — "downloads fail / stuck resolving":
                // DownloadProvider.download() (Dart) was calling
                // ApiService.resolveStreamUrl() directly — the OLD,
                // Worker-only resolve chain (Cloudflare Worker's SABR-gated
                // YouTube clients + Piped fallback), completely bypassing
                // the native YoutubeInnertube/NewPipeExtractor path that
                // HybridStreamResolver already gives live playback. Live
                // playback got reliable once NewPipeExtractor was bumped to
                // v0.26.3, but downloads never benefited from that fix
                // because they never went through this resolver at all.
                //
                // This exposes the SAME resolver playback uses
                // (native-first via YoutubeInnertube, falling back to the
                // Worker/Dart chain only if the native attempt genuinely
                // fails) as a standalone, one-shot method call — no queue,
                // no player state, no engine side effects. Dart's
                // DownloadProvider calls this instead of
                // ApiService.resolveStreamUrl() directly for youtube-source
                // downloads (see NativeEngineBridge.resolveForDownload +
                // the corresponding DownloadProvider change).
                "resolveForDownload" -> {
                    val song = parseSong(call.argument<Map<String, Any?>>("song")!!)
                    scope.launch {
                        val url = try {
                            resolver.resolve(song, forceRefresh = false)
                        } catch (e: Exception) {
                            null
                        }
                        result.success(url)
                    }
                }

                // ── Auto Sleep Guard ────────────────────────────────────
                // Battery feature, independent of the Dart Sleep Timer —
                // see AutoSleepGuard.kt for the full design rationale.

                "autoSleepGuardGetState" -> {
                    val isSignedIn = AuthStateBridge.isSignedIn
                    result.success(
                        mapOf(
                            "enabled" to AutoSleepGuard.isEnabled(appContext),
                            "durationHours" to AutoSleepGuard.durationHours(appContext, isSignedIn),
                            "isSignedIn" to isSignedIn,
                        )
                    )
                }
                "autoSleepGuardSetDurationHours" -> {
                    val hours = call.argument<Int>("hours") ?: 3
                    AutoSleepGuard.setDurationHours(appContext, hours)
                    result.success(null)
                }
                // User-facing Automatic/Off toggle. Off is a full
                // shutdown (cancels any pending alarm/grace-timeout and
                // dismisses an outstanding "Still there?" prompt); back to
                // Automatic resumes properly right away, same as the plan
                // called for — see AutoSleepGuard.setEnabled.
                "autoSleepGuardSetEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    AutoSleepGuard.setEnabled(appContext, enabled)
                    result.success(null)
                }
                // Pushed by SleepTimerService (Dart) on every start/cancel/
                // expire, so the native guard never has to poll Dart to
                // know whether it should stay out of the way.
                "autoSleepGuardSetSleepTimerActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    AutoSleepGuard.setSleepTimerActive(active)
                    result.success(null)
                }
                // Pushed by AuthProvider (Dart) on every auth state change.
                "autoSleepGuardSetSignedIn" -> {
                    val signedIn = call.argument<Boolean>("signedIn") ?: false
                    AuthStateBridge.isSignedIn = signedIn
                    result.success(null)
                }
                // Explicit in-app tap activity (play/pause/skip/seek
                // buttons in the Dart UI, distinct from the native
                // notification/lock-screen controls which are already
                // covered by the player listener in
                // AurumMediaSessionService). Screen-unlock activity is
                // reported the same way from MainActivity's onResume.
                "autoSleepGuardRecordActivity" -> {
                    AutoSleepGuard.recordActivity(appContext)
                    result.success(null)
                }
                // Polled once on app open (not periodically) to drive the
                // "Paused after inactivity at 4:12 AM — Resume?" prompt.
                "autoSleepGuardPeekLastAutoPause" -> {
                    result.success(AutoSleepGuard.peekLastAutoPause(appContext))
                }
                "autoSleepGuardConsumeLastAutoPause" -> {
                    AutoSleepGuard.consumeLastAutoPause(appContext)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("AUDIO_ENGINE_ERROR", e.message, null)
        }
    }

    /**
     * Called from MainActivity.onDestroy(). THE actual fix for
     * "background/lock-screen band ho jaata hai": this used to call
     * engine.release(), which calls player.release() on the SAME ExoPlayer
     * instance AurumMediaSessionService's MediaSession is built on (they
     * share one AurumAudioEngine — see sharedEngine). MainActivity gets
     * destroyed far more often than people expect (recents swipe, screen
     * rotation edge cases, OS reclaiming the activity while the process
     * stays alive) — every one of those was silently killing playback and
     * tearing down the MediaSession, even mid-song.
     *
     * The Activity does not own the engine's lifecycle; the foreground
     * service does. All this should do is stop forwarding state to a
     * now-dead Dart EventChannel sink. The engine/player stays alive and
     * keeps playing in the background; AurumMediaSessionService.onTaskRemoved
     * already contains the correct logic for stopping the player when
     * that's actually appropriate (nothing queued / not playing).
     */
    fun release() {
        stateJob?.cancel()
        engine.castManager.onStateChanged = null
        // NOTE: onSessionStarted/onSessionEnded are deliberately NOT
        // cleared here — engine (and its castManager) is the shared,
        // service-owned instance (see sharedEngine), which can outlive
        // this particular MainActivity/handler instance (e.g. Activity
        // recreated on rotation). Clearing them would silently break
        // cast handoff for the next handler instance that attaches to
        // the same shared engine. Only per-Activity state (the
        // EventChannel sink callback above) is torn down here.
    }
}
