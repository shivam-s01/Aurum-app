package com.aurum.music

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import androidx.media3.common.Player
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * Replaces audio_service's `AudioService` + `AurumAudioHandler` entirely.
 * Owns [AurumAudioEngine] (which owns the actual ExoPlayer) and wraps it in
 * a real MediaSession — Media3 auto-generates the lock-screen/notification
 * UI (MediaStyle notification, play/pause/next/prev, artwork, Bluetooth,
 * Android Auto) directly from the player + session state, so none of that
 * needs to be hand-built here.
 *
 * Held as a singleton by [AurumEngineChannelHandler] via [MainActivity] so
 * that MethodChannel calls from Dart (playQueue, playSong, etc.) and this
 * service operate on the SAME AurumAudioEngine/ExoPlayer instance — the
 * service is just the foreground/notification wrapper around it, not a
 * second player.
 */
class AurumMediaSessionService : MediaSessionService() {

    companion object {
        private const val LIKE_ACTION = "com.aurum.music.ACTION_TOGGLE_LIKE"
        private const val NOTIFICATION_CHANNEL_ID = "aurum_playback"
        private const val NOTIFICATION_ID = 1001

        // Set by AurumEngineChannelHandler right after it constructs the
        // engine (MainActivity.configureFlutterEngine runs before this
        // service's onCreate in practice, but we guard with a null check +
        // late binding regardless — see onCreate()).
        var sharedEngine: AurumAudioEngine? = null

        // Live instance, set/cleared in onCreate()/onDestroy(). Lets
        // AurumEngineChannelHandler push an immediate notification refresh
        // (e.g. after setCurrentSongLiked) without waiting for the next
        // player event to happen to fire onMediaMetadataChanged.
        var instance: AurumMediaSessionService? = null
    }

    private var mediaSession: MediaSession? = null
    private var notificationProvider: androidx.media3.session.DefaultMediaNotificationProvider? = null
    private val likeCommand = SessionCommand(LIKE_ACTION, Bundle.EMPTY)

    override fun onCreate() {
        super.onCreate()
        instance = this

        // Explicitly wire Media3's own notification provider instead of
        // relying purely on its implicit default. THE actual second bug
        // (after the earlier release()-kills-the-player fix): a separate
        // plain NotificationCompat notification (no MediaStyle) was being
        // posted via startForeground() under its own ID, while Media3's
        // own MediaNotificationManager built a DIFFERENT, real MediaStyle
        // notification once the session/player were ready. Two
        // notifications existed; the plain one (posted first) "won" the
        // visible slot, and it had no transport controls because it was
        // never MediaStyle — hence "name dikh raha hai, controls nahi".
        //
        // Fix: grab the SAME DefaultMediaNotificationProvider Media3 uses
        // internally, build the real MediaStyle notification with it
        // ourselves once mediaSession exists (see below), and post that
        // via startForeground(). Only one notification ever exists now,
        // and it's MediaStyle (title/artist/artwork/play-pause-next-prev)
        // from the very first frame it's shown.
        notificationProvider = androidx.media3.session.DefaultMediaNotificationProvider
            .Builder(this)
            .setChannelId(NOTIFICATION_CHANNEL_ID)
            .setChannelName(androidx.media3.session.R.string.default_notification_channel_name)
            .build()
        setMediaNotificationProvider(notificationProvider!!)
        createNotificationChannelIfNeeded()

        val engine = sharedEngine ?: run {
            // Defensive fallback: service was started (e.g. by the OS
            // restoring a sticky foreground service after process death)
            // before Dart/MainActivity ever constructed AurumEngineChannelHandler.
            // We cannot safely build a second ExoPlayer here (would fight
            // the real one for audio focus/output), so bail out quietly —
            // the service will be recreated correctly once MainActivity
            // actually launches and wires sharedEngine.
            stopSelf()
            return
        }

        val likeButton = CommandButton.Builder()
            .setDisplayName(if (engine.isCurrentSongLiked()) "Unlike" else "Like")
            .setSessionCommand(likeCommand)
            .setIconResId(
                if (engine.isCurrentSongLiked()) R.drawable.ic_like_filled
                else R.drawable.ic_like_outline
            )
            .build()

        val sessionActivityIntent = packageManager
            .getLaunchIntentForPackage(packageName)
            ?.let { intent ->
                PendingIntent.getActivity(
                    this, 0, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }

        val callback = object : MediaSession.Callback {
            override fun onConnect(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
            ): MediaSession.ConnectionResult {
                val result = MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                    .setAvailableSessionCommands(
                        MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS
                            .buildUpon()
                            .add(likeCommand)
                            .build()
                    )
                    .build()
                return result
            }

            override fun onPostConnect(session: MediaSession, controller: MediaSession.ControllerInfo) {
                super.onPostConnect(session, controller)
                session.setCustomLayout(ImmutableList.of(likeButton))
            }

            override fun onCustomCommand(
                session: MediaSession,
                controller: MediaSession.ControllerInfo,
                customCommand: SessionCommand,
                args: Bundle,
            ): ListenableFuture<SessionResult> {
                if (customCommand.customAction == LIKE_ACTION) {
                    engine.triggerLikeToggle()
                }
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
        }

        val sessionBuilder = MediaSession.Builder(this, engine.player)
            .setCallback(callback)
        if (sessionActivityIntent != null) {
            sessionBuilder.setSessionActivity(sessionActivityIntent)
        }
        mediaSession = sessionBuilder.build()

        // Defensive safety-net for aggressive OEM battery managers
        // (ColorOS/realme UI and similar) that have been observed killing
        // this service within moments of creation, before Media3's own
        // internal auto-promotion has a chance to fire on the first player
        // event. Building Media3's own real notification here manually
        // (via notificationProvider.createNotification(...)) requires an
        // ActionFactory instance that Media3 1.4.1 doesn't expose a public
        // DEFAULT/no-op implementation for, so that approach doesn't
        // compile. Instead: post a minimal MediaStyle notification built
        // with MediaStyleNotificationHelper (stable public API, correctly
        // associates the notification with mediaSession so it's real
        // MediaStyle, not a plain notification) as the immediate
        // OEM-kill safety net. Media3's own MediaNotificationManager takes
        // over and replaces this with its fully-featured notification
        // (title/artist/artwork/play-pause-next-prev) the moment player
        // state is available — same notification ID/channel, so there is
        // still only ever one notification visible.
        //
        // This MUST happen before addSession() below: addSession() can
        // itself trigger an immediate notification-refresh attempt (e.g.
        // if playWhenReady is already true by the time this runs), and
        // that refresh calls startForeground() internally. Calling our
        // own startForeground() first guarantees the service is already
        // in the foreground state before Media3's internal machinery ever
        // tries to touch it — avoiding a startForeground-ordering race.
        val placeholderNotification = androidx.core.app.NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Aurum")
            .setContentText("Loading…")
            .setSmallIcon(R.drawable.ic_like_outline)
            .setOngoing(true)
            .setStyle(
                androidx.media3.session.MediaStyleNotificationHelper
                    .MediaStyle(mediaSession!!)
            )
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                placeholderNotification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, placeholderNotification)
        }

        // THE actual root cause of "Loading... kabhi update nahi hota":
        // Media3's MediaNotificationManager (the thing that rebuilds the
        // notification whenever player/metadata state changes) only ever
        // starts listening to a session once MediaSessionService.addSession()
        // is called on it. That call normally happens automatically inside
        // MediaSessionService's own onBind()/connect() handling — but ONLY
        // when a real androidx.media3.session.MediaController connects to
        // this service. MainActivity's bindService() is a plain Android
        // service bind, not a MediaController connection, so that path
        // never fires and addSession() was never being called — the
        // session existed and had a real player attached, but the
        // notification manager didn't know it existed, so it never
        // refreshed past the placeholder text. Calling addSession()
        // ourselves, right here, is what actually wires up live title/
        // artist/artwork + control-state updates on every player event.
        addSession(mediaSession!!)

        // THE actual fix for "background/lock-screen kuch nahi ho raha":
        // Media3's MediaSessionService base class owns an internal
        // MediaNotificationManager that listens to player events and
        // rebuilds a proper MediaStyle notification (title/artist/artwork/
        // play-pause-next-prev controls) whenever they change — from
        // engine.player's current MediaMetadata (already wired in
        // AurumAudioEngine's buildMediaItem). It automatically upgrades
        // the placeholder notification posted above into the real one and
        // keeps it in sync; nothing further needs to be built by hand here.
        // We do NOT call stopForeground() anywhere ourselves — Media3
        // demotes/cleans up on its own once playback stops, and stopSelf()
        // (see onTaskRemoved/the sharedEngine-null branch above) tears the
        // notification down as part of normal service destruction.

        // Keep the notification's like-button icon in sync whenever the
        // engine's liked state changes (e.g. FavoritesProvider toggled from
        // inside the app, or a successful reverse-channel toggle from this
        // very button). Re-pushing the custom layout on every playback
        // state change would be wasteful, so we piggyback on the existing
        // player listener instead of polling.
        engine.player.addListener(object : Player.Listener {
            override fun onMediaMetadataChanged(mediaMetadata: androidx.media3.common.MediaMetadata) {
                refreshLikeButton(engine)
            }
        })
    }

    private fun createNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Playback",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun refreshLikeButton(engine: AurumAudioEngine) {
        val session = mediaSession ?: return
        val liked = engine.isCurrentSongLiked()
        val button = CommandButton.Builder()
            .setDisplayName(if (liked) "Unlike" else "Like")
            .setSessionCommand(likeCommand)
            .setIconResId(
                if (liked) R.drawable.ic_like_filled else R.drawable.ic_like_outline
            )
            .build()
        session.setCustomLayout(ImmutableList.of(button))
    }

    /** Public hook AurumEngineChannelHandler calls after setCurrentSongLiked()
     *  so the notification button updates immediately rather than waiting
     *  for the next media-metadata-changed event. */
    fun onLikedStateChanged() {
        sharedEngine?.let { refreshLikeButton(it) }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    // I13: when the user swipes the app away from recents, stop playback +
    // the foreground service instead of leaving a silent phantom session
    // alive — matches audio_service's `stopWithTask="true"` behavior that
    // was configured in the old AndroidManifest.xml service entry.
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = mediaSession?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        mediaSession?.run {
            removeSession(this)
            player.release()
            release()
            mediaSession = null
        }
        instance = null
        super.onDestroy()
    }
}
