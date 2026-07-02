package com.aurum.music

import android.app.PendingIntent
import android.content.Intent
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
    private val likeCommand = SessionCommand(LIKE_ACTION, Bundle.EMPTY)

    override fun onCreate() {
        super.onCreate()
        instance = this

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
            player.release()
            release()
            mediaSession = null
        }
        instance = null
        super.onDestroy()
    }
}
