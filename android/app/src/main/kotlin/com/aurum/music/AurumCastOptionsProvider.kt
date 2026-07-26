package com.aurum.music

import android.content.Context
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.NotificationOptions

/**
 * Referenced by AndroidManifest's OPTIONS_PROVIDER_CLASS_NAME meta-data.
 * This is the one required hook point for bootstrapping the Cast SDK —
 * CastContext.getSharedInstance() looks this class up by reflection the
 * first time any Cast API is touched, so it must exist even though
 * nothing calls it directly from Kotlin.
 *
 * WHY DEFAULT_MEDIA_RECEIVER_APPLICATION_ID: Aurum doesn't ship a custom
 * Cast receiver (that's a separate web app registered with Google, a much
 * bigger and separate undertaking — the AurumTV native app is NOT a Cast
 * receiver, they're unrelated). Google's default media receiver is a
 * generic, always-available Cast receiver built for exactly this case:
 * apps that just need to push a standard audio/video MediaInfo (title,
 * artist, artwork URL, content URL, MIME type) to any Cast device without
 * hosting their own receiver web app. It renders a clean default
 * "Now Playing" UI on the TV — album art, title, artist, progress bar —
 * which is exactly what a music app casting a stream URL needs, and every
 * Cast-certified device already knows how to launch it.
 */
class AurumCastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions {
        val notificationOptions = NotificationOptions.Builder()
            // Action buttons shown on the *casting phone's* lock-screen
            // Cast notification (separate from the TV's own receiver UI).
            // Play/pause + skip-next mirrors what Spotify/YT Music show
            // there — enough control without cluttering it.
            .setActions(
                listOf(
                    com.google.android.gms.cast.MediaIntentReceiver.ACTION_TOGGLE_PLAYBACK,
                    com.google.android.gms.cast.MediaIntentReceiver.ACTION_SKIP_NEXT,
                ),
                intArrayOf(0, 1),
            )
            .build()

        val mediaOptions = CastMediaOptions.Builder()
            .setNotificationOptions(notificationOptions)
            // We drive our own mini/full player UI on the phone (matching
            // Aurum's existing design) rather than the Cast SDK's built-in
            // "expanded controller" activity, so we don't launch one
            // automatically on session start.
            .setMediaSessionEnabled(true)
            .build()

        return CastOptions.Builder()
            .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
            .setCastMediaOptions(mediaOptions)
            // Stops the Cast SDK from also auto-reconnecting to a
            // previously-cast-to device on cold app start before the user
            // has interacted with anything this session — AurumCastManager
            // decides reconnect behavior explicitly instead.
            .setResumeSavedSession(false)
            .build()
    }

    // No custom SessionProvider needed — CastOptions above is sufficient
    // for a single default-receiver Cast session type.
    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
