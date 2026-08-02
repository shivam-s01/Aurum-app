package com.aurum.music

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * Auto Sleep Guard — battery feature, fully separate from the user-facing
 * Sleep Timer (SleepTimerService, Dart side).
 *
 * WHEN IT RUNS: only when the Dart-side Sleep Timer is NOT active. If the
 * user has a sleep timer running, this stays completely silent — see
 * [setSleepTimerActive], pushed from Dart on every SleepTimerService
 * start/cancel/expire so this native singleton always has a fresh view of
 * that state without polling Dart for it.
 *
 * WHAT IT DOES: if playback is ongoing and there has been no "activity"
 * (screen unlock, in-app tap: play/pause/skip/seek) for N hours (3 or 5,
 * see [DurationHours]), playback is paused automatically to save battery.
 *
 * ACCESS: available to every signed-in user (free or premium) — gated by
 * Google/Supabase sign-in only, not by PremiumProvider. Free users get a
 * hardcoded 5h duration with no settings UI; signed-in users (regardless
 * of plan) who open the dedicated settings card can choose 3h or 5h, saved
 * permanently in SharedPreferences until they change it again.
 *
 * IMPLEMENTATION: intentionally has NO Dart Timer, NO polling loop, and NO
 * WorkManager dependency (not present in this project's build.gradle, and
 * adding it purely for one occasional one-shot alarm isn't worth the new
 * dependency surface). Instead: a single inexact AlarmManager alarm,
 * rescheduled only when playback-affecting activity actually happens —
 * exactly the same "reschedule on event, not on a loop" shape the plan
 * called for, built on a primitive already available on every Android
 * version without any special permission.
 *
 * Deliberately uses `set(...)` / `setAndAllowWhileIdle(...)` — NOT
 * `setExactAndAllowWhileIdle(...)`. Exact alarms require the
 * SCHEDULE_EXACT_ALARM permission on Android 12+, which is a sensitive
 * permission that triggers extra Play Store policy review for something
 * that has zero user-facing reason to fire at a precise millisecond — a
 * battery-saving pause landing a few minutes late is invisible to the
 * user and saves us that entire review surface.
 */
object AutoSleepGuard {
    private const val TAG = "AutoSleepGuard"
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY_DURATION_HOURS = "flutter.auto_sleep_guard_hours"
    private const val KEY_ENABLED = "flutter.auto_sleep_guard_enabled"
    private const val KEY_LAST_AUTO_PAUSE_AT = "flutter.auto_sleep_guard_last_pause_at"
    private const val KEY_LAST_AUTO_PAUSE_CONSUMED = "flutter.auto_sleep_guard_last_pause_consumed"

    private const val ACTION_CHECK = "com.aurum.music.action.AUTO_SLEEP_GUARD_CHECK"
    private const val REQUEST_CODE = 7742

    private const val NOTIFICATION_CHANNEL_ID = "aurum_auto_sleep_guard"
    private const val NOTIFICATION_ID = 1002

    private const val DEFAULT_FREE_HOURS = 5

    enum class DurationHours(val hours: Int) { THREE(3), FIVE(5) }

    // Updated from Dart whenever SleepTimerService starts/cancels/expires
    // (see AurumEngineChannelHandler's "setSleepTimerActive" method and
    // SleepTimerService's calls into it). Defaults to false so a guard
    // check that somehow runs before Dart has ever reported in does not
    // get permanently blocked.
    @Volatile
    private var sleepTimerActive: Boolean = false

    // Wall-clock timestamp (System.currentTimeMillis) of the last
    // registered activity. Volatile: written from the player-listener
    // thread (main), read from the alarm receiver, which also runs on
    // main — kept volatile regardless as a cheap safety net against any
    // future caller off the main thread.
    @Volatile
    private var lastActivityAtMs: Long = System.currentTimeMillis()

    fun setSleepTimerActive(active: Boolean) {
        sleepTimerActive = active
    }

    /** Call on: screen unlock, and any in-app play/pause/skip/seek tap. */
    fun recordActivity(context: Context) {
        lastActivityAtMs = System.currentTimeMillis()
        if (awaitingConfirmation) {
            // Any real activity (unlock, in-app tap) while a confirmation
            // prompt is outstanding already answers the question — no
            // need to make the user separately tap "Yes" too.
            awaitingConfirmation = false
            dismissConfirmationPrompt(context)
        }
        // Reschedule relative to this fresh activity instead of leaving
        // the old alarm in place — this IS the "reschedule on activity
        // reset" the plan called for, and it's why no periodic loop is
        // needed: the alarm only ever needs to know about the most recent
        // activity, and every call here supersedes the previous one.
        scheduleNextCheck(context)
    }

    /** Call whenever playback starts/resumes/stops, so we only ever have
     *  an alarm scheduled while there's actually something to guard. */
    fun onPlaybackStateChanged(context: Context, isPlaying: Boolean) {
        if (isPlaying) {
            // Treat a fresh play as activity too — covers the case where
            // the user pressed play and then put the phone down; the
            // inactivity window should start counting from there, not
            // from whatever stale timestamp preceded it.
            recordActivity(context)
        } else {
            cancelScheduledCheck(context)
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** Effective duration: free users are hardcoded to 5h with no choice;
     *  signed-in users who've picked 3h keep that until they change it. */
    fun durationHours(context: Context, isSignedIn: Boolean): Int {
        if (!isSignedIn) return DEFAULT_FREE_HOURS
        val stored = prefs(context).getInt(KEY_DURATION_HOURS, DEFAULT_FREE_HOURS)
        return if (stored == DurationHours.THREE.hours) DurationHours.THREE.hours else DurationHours.FIVE.hours
    }

    fun setDurationHours(context: Context, hours: Int) {
        val clamped = if (hours == DurationHours.THREE.hours) DurationHours.THREE.hours else DurationHours.FIVE.hours
        prefs(context).edit().putInt(KEY_DURATION_HOURS, clamped).apply()
    }

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
        if (!enabled) cancelScheduledCheck(context)
    }

    /** Returns the epoch-millis timestamp of the last auto-pause if it
     *  hasn't been shown/consumed yet (for the "Paused after inactivity at
     *  4:12 AM — Resume?" prompt), else null. Consuming (see
     *  [consumeLastAutoPause]) is separate from reading so the UI can
     *  decide when the prompt has actually been shown to the user. */
    fun peekLastAutoPause(context: Context): Long? {
        val p = prefs(context)
        if (p.getBoolean(KEY_LAST_AUTO_PAUSE_CONSUMED, true)) return null
        val at = p.getLong(KEY_LAST_AUTO_PAUSE_AT, -1L)
        return if (at > 0) at else null
    }

    fun consumeLastAutoPause(context: Context) {
        prefs(context).edit().putBoolean(KEY_LAST_AUTO_PAUSE_CONSUMED, true).apply()
    }

    private fun alarmManager(context: Context) =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, AutoSleepGuardReceiver::class.java).apply {
            action = ACTION_CHECK
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    private fun scheduleNextCheck(context: Context) {
        if (!isEnabled(context)) return
        if (sleepTimerActive) {
            // Sleep Timer owns pausing right now — stay completely out of
            // the way, including not holding a stale alarm in the queue.
            cancelScheduledCheck(context)
            return
        }
        val isSignedIn = try {
            AuthStateBridge.isSignedIn
        } catch (e: Exception) {
            false
        }
        if (!isSignedIn) {
            // Feature is Google/Supabase-sign-in gated at the guard level
            // (per product decision — free users get it too, but ONLY
            // once signed in; this is the enforcement point).
            cancelScheduledCheck(context)
            return
        }

        val hours = durationHours(context, isSignedIn)
        val triggerAtElapsed = SystemClock.elapsedRealtime() + hours * 60L * 60L * 1000L

        try {
            alarmManager(context).setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAtElapsed,
                pendingIntent(context),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule Auto Sleep Guard alarm: ${e.message}", e)
        }
    }

    private fun cancelScheduledCheck(context: Context) {
        try {
            alarmManager(context).cancel(pendingIntent(context))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cancel Auto Sleep Guard alarm: ${e.message}", e)
        }
    }

    /** Invoked by [AutoSleepGuardReceiver] when the alarm fires. Two-stage
     *  flow: first fires an "Are you awake?" confirmation instead of
     *  pausing immediately — a genuinely awake user (working, listening to
     *  a podcast, just not touching the phone) gets a chance to say so
     *  with one tap. Only pauses if there's truly no response within the
     *  grace window, which is the only reliable way to tell "awake but not
     *  touching the phone" apart from "actually asleep" without invasive
     *  sensors (motion/mic false-trigger in both directions — a sleeping
     *  person shifts in bed, an awake person working at a desk can leave
     *  the phone perfectly still for hours). */
    internal fun onAlarmFired(context: Context) {
        if (!isEnabled(context) || sleepTimerActive) return

        val engine = AurumMediaSessionService.sharedEngine ?: return
        val player = engine.player
        val isActivelyPlaying = player.playWhenReady && player.mediaItemCount > 0
        if (!isActivelyPlaying) return

        val isSignedIn = try { AuthStateBridge.isSignedIn } catch (e: Exception) { false }
        if (!isSignedIn) return

        val hoursMs = durationHours(context, isSignedIn) * 60L * 60L * 1000L
        val elapsedSinceActivity = System.currentTimeMillis() - lastActivityAtMs

        if (elapsedSinceActivity < hoursMs) {
            // Woken slightly early (inexact alarm drift) — just
            // reschedule against the real remaining time instead of
            // prompting prematurely.
            scheduleNextCheck(context)
            return
        }

        if (awaitingConfirmation) {
            // A confirmation prompt is already outstanding (grace window
            // hasn't elapsed yet) — this alarm firing again means the
            // grace period itself has now ended with no response.
            pauseNow(context)
            return
        }

        postConfirmationPrompt(context)
        awaitingConfirmation = true
        scheduleGraceTimeout(context)
    }

    // Set true the moment a confirmation prompt is posted, cleared either
    // by [onConfirmedAwake] (Yes / notification tap) or by [pauseNow]
    // (No / grace timeout elapsed) — never left dangling either way.
    @Volatile
    private var awaitingConfirmation: Boolean = false

    private const val GRACE_WINDOW_MS = 8L * 60L * 1000L // 8 minutes

    private fun scheduleGraceTimeout(context: Context) {
        val triggerAtElapsed = SystemClock.elapsedRealtime() + GRACE_WINDOW_MS
        try {
            alarmManager(context).setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAtElapsed,
                pendingIntent(context),
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule Auto Sleep Guard grace timeout: ${e.message}", e)
        }
    }

    /** Called from [AutoSleepGuardActionReceiver] when the user taps "Yes"
     *  or taps the notification body itself (both mean "I'm here"). */
    internal fun onConfirmedAwake(context: Context) {
        awaitingConfirmation = false
        dismissConfirmationPrompt(context)
        recordActivity(context) // resets the countdown and reschedules cleanly
    }

    /** Called from [AutoSleepGuardActionReceiver] when the user explicitly
     *  taps "No" — no need to wait out the rest of the grace window. */
    internal fun onConfirmedAsleep(context: Context) {
        pauseNow(context)
    }

    private fun pauseNow(context: Context) {
        awaitingConfirmation = false
        dismissConfirmationPrompt(context)

        val engine = AurumMediaSessionService.sharedEngine ?: return
        // Smooth wind-down instead of an abrupt cut, matching the
        // existing Sleep Timer's fade-out behavior for consistency.
        try {
            engine.sleepFadeOutAndPause(fadeMs = 8000)
        } catch (e: Exception) {
            Log.e(TAG, "Auto Sleep Guard pause failed: ${e.message}", e)
            return
        }

        val now = System.currentTimeMillis()
        prefs(context).edit()
            .putLong(KEY_LAST_AUTO_PAUSE_AT, now)
            .putBoolean(KEY_LAST_AUTO_PAUSE_CONSUMED, false)
            .apply()

        postPauseNotification(context)
    }

    private fun postPauseNotification(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!granted) return
        }
        createNotificationChannelIfNeeded(context)

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                context, 0, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        val hours = durationHours(context, true)
        val notification = Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_widget_pause)
            .setContentTitle("Playback paused")
            .setContentText("Inactive for $hours hours — tap to resume")
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()

        try {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post Auto Sleep Guard notification: ${e.message}", e)
        }
    }

    // ── Confirmation prompt ("Are you awake?") ─────────────────────────────
    // Fires instead of pausing immediately once the inactivity window
    // elapses — gives a genuinely awake-but-not-touching-the-phone user
    // (working, listening to a podcast) one tap to say so, before playback
    // is assumed to be unattended and paused. See onAlarmFired's doc
    // comment for why this two-stage approach exists.

    private const val CONFIRM_NOTIFICATION_ID = 1003
    private const val ACTION_CONFIRM_AWAKE = "com.aurum.music.action.AUTO_SLEEP_GUARD_YES"
    private const val ACTION_CONFIRM_ASLEEP = "com.aurum.music.action.AUTO_SLEEP_GUARD_NO"

    private fun postConfirmationPrompt(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            // No notification permission: fall back to the old behavior
            // (pause directly) rather than silently waiting out a grace
            // window the user has no way to see or respond to — leaving
            // this case waiting invisibly for 8 minutes would just be a
            // longer, equally silent pause with no benefit.
            if (!granted) {
                pauseNow(context)
                return
            }
        }
        createNotificationChannelIfNeeded(context)

        // Tapping the notification body itself counts as "I'm here" —
        // same as explicitly tapping Yes. Uses the launch intent (not a
        // broadcast) so it also brings the app forward, matching normal
        // notification-tap expectations.
        val bodyTapIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.let {
                it.putExtra("auto_sleep_guard_confirm", true)
                PendingIntent.getActivity(
                    context, 1, it,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }

        val yesIntent = Intent(context, AutoSleepGuardActionReceiver::class.java).apply {
            action = ACTION_CONFIRM_AWAKE
        }
        val yesPendingIntent = PendingIntent.getBroadcast(
            context, 2, yesIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val noIntent = Intent(context, AutoSleepGuardActionReceiver::class.java).apply {
            action = ACTION_CONFIRM_ASLEEP
        }
        val noPendingIntent = PendingIntent.getBroadcast(
            context, 3, noIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_widget_pause)
            .setContentTitle("Still there?")
            .setContentText("No activity for a while — pausing soon to save battery")
            .setOngoing(true) // not swipe-dismissable — this needs an explicit answer, not an accidental swipe
            .setContentIntent(bodyTapIntent)
            .addAction(Notification.Action.Builder(0, "Yes, I'm here", yesPendingIntent).build())
            .addAction(Notification.Action.Builder(0, "No, pause", noPendingIntent).build())
            .build()

        try {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.notify(CONFIRM_NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to post Auto Sleep Guard confirmation prompt: ${e.message}", e)
        }
    }

    private fun dismissConfirmationPrompt(context: Context) {
        try {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            manager.cancel(CONFIRM_NOTIFICATION_ID)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to dismiss Auto Sleep Guard confirmation prompt: ${e.message}", e)
        }
    }

    private fun createNotificationChannelIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Auto Sleep Guard",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }
}

/**
 * Thin static bridge so AutoSleepGuard (no Dart/BuildContext access) can
 * read current sign-in state. Set from AurumEngineChannelHandler's
 * "setSignedIn" method call, pushed from Dart's AuthProvider whenever
 * auth state changes (see AuthProvider.init's authStateChanges listener).
 */
object AuthStateBridge {
    @Volatile
    var isSignedIn: Boolean = false
}

/** Fires when the AlarmManager alarm goes off. Deliberately minimal —
 *  hands off to AutoSleepGuard immediately, does no work itself. */
class AutoSleepGuardReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AutoSleepGuard.onAlarmFired(context.applicationContext)
    }
}

/** Handles the "Yes, I'm here" / "No, pause" actions on the "Still
 *  there?" confirmation prompt. Kept separate from
 *  [AutoSleepGuardReceiver] so the two intents can never be confused with
 *  each other regardless of how their extras/actions are read. */
class AutoSleepGuardActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        when (intent.action) {
            "com.aurum.music.action.AUTO_SLEEP_GUARD_YES" -> AutoSleepGuard.onConfirmedAwake(appContext)
            "com.aurum.music.action.AUTO_SLEEP_GUARD_NO" -> AutoSleepGuard.onConfirmedAsleep(appContext)
        }
    }
}
