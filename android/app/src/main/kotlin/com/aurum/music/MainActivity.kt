package com.aurum.music

import android.content.ComponentName
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.util.Log
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterFragmentActivity() {

    companion object {
        private const val CHANNEL = "com.aurum.music/media_store"
        private const val TAG = "AurumMainActivity"
        private val ALBUM_ART_URI = Uri.parse("content://media/external/audio/albumart")
        private const val MIN_SIZE_BYTES = 500_000L
    }

    // Owns the native audio engine's MethodChannel/EventChannel wiring
    // (playQueue/playSong/.../state stream/error stream/like-toggle
    // reverse channel). Constructed once per Flutter engine attach —
    // AurumMediaSessionService.sharedEngine is set inside its init{} so the
    // service (bound below, right after this) always finds the same
    // ExoPlayer instance instead of building a second one.
    // Held so AurumSilentInstaller's async install callback (which can
    // fire well after the "installApk" method-channel call itself already
    // returned — PackageInstaller sessions are inherently async, often
    // waiting on a user tapping a confirmation screen) has a channel to
    // call back into Dart on with the real success/failure outcome.
    private var methodChannel: MethodChannel? = null

    private var audioEngineChannelHandler: AurumEngineChannelHandler? = null

    // Exposes YoutubeInnertube.getRelated() (YouTube's own related-videos
    // graph) to Dart for use as a getAutoQueue signal — fully separate
    // channel from audio engine playback commands, see
    // AurumRelatedChannelHandler's doc comment for why.
    private var relatedChannelHandler: AurumRelatedChannelHandler? = null

    // Live battery-percentage stream powering Settings → Player & Audio →
    // "Battery Saver Mode" — see AurumBatteryChannelHandler's doc comment.
    private var batteryChannelHandler: AurumBatteryChannelHandler? = null

    // THE fix for "background/lock-screen kuch nahi ho raha": previously
    // nothing ever bound to or started AurumMediaSessionService, so its
    // onCreate()/onGetSession() never ran and no MediaSession was ever
    // actually live — the notification/lock-screen controls had nothing
    // to attach to. bindService() (not startForegroundService — that path
    // is what caused the earlier ForegroundServiceDidNotStartInTimeException
    // crash) is the documented way to bring a MediaSessionService to life:
    // it has no 5-second foreground-promotion deadline, and the service's
    // own internal MediaNotificationManager promotes to foreground on its
    // own once real playback starts (see AurumMediaSessionService.kt).
    private var mediaSessionServiceConnection: ServiceConnection? = null

    // We call androidx.core.splashscreen's installSplashScreen() (see
    // onCreate() below) for the compat library's per-OEM normalization
    // (see styles.xml's LaunchTheme doc comment). Splash icon is now the
    // plain static app logo (ic_launcher) with animationDuration=0 — no
    // animated-vector spin/morph anymore, just the logo shown while the
    // app starts.

    override fun onCreate(savedInstanceState: Bundle?) {
        // installSplashScreen() MUST be called before super.onCreate() —
        // that's the documented contract of androidx.core.splashscreen
        // (it needs to read/modify the window before the Activity's
        // content is set up). This call reads LaunchTheme's
        // postSplashScreenTheme attribute (styles.xml) and switches the
        // Activity to NormalTheme automatically once the splash is
        // dismissed — this REPLACES the old manual
        // setTheme(R.style.NormalTheme) call below; calling both would
        // apply NormalTheme redundantly (harmless) but the explicit
        // manual call is removed to avoid two different code paths
        // trying to manage the same theme transition.
        //
        installSplashScreen()

        // FIX (gray/white screen flash on cold start, swipe-down full-player
        // dismiss, and back-navigation): the Activity used to stay on
        // LaunchTheme's windowBackground (a static launch_background
        // drawable) for its entire life, not just the splash instant,
        // because nothing ever switched it to NormalTheme's correct dark
        // background. Every time the Android window surface got
        // recreated/redrawn before Flutter's next frame was composited
        // (cold start, and any full-screen surface change like a route
        // transition or the full player's swipe-to-dismiss), the OS
        // briefly showed that stale window background — which read as a
        // gray flash. NOW HANDLED by postSplashScreenTheme above
        // (styles.xml) instead of a manual setTheme() call — same effect,
        // but timed and managed by the splash-screen library itself
        // rather than racing its own internal theme resolution.
        super.onCreate(savedInstanceState)
        // Diagnostic log — crashes, ANR, offload status, playback/network
        // errors all funnel into one rotating file from here on. Init'd as
        // early as possible so nothing in startup is missed. See
        // AurumDiagnosticLog.kt for the full design reasoning.
        AurumDiagnosticLog.init(this)
        // Apply the saved High Refresh Rate preference immediately at
        // launch — without this, the setting would only take effect after
        // the user re-opens Settings and toggles it again post-launch,
        // since Flutter's own setHighRefreshRate call only fires from the
        // Settings screen, not on cold start.
        val enabled = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.high_refresh_rate", false)
        applyHighRefreshRate(enabled)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioEngineChannelHandler = AurumEngineChannelHandler(this, flutterEngine.dartExecutor.binaryMessenger, flutterEngine.renderer)
        bindMediaSessionService()

        relatedChannelHandler = AurumRelatedChannelHandler(flutterEngine.dartExecutor.binaryMessenger)

        batteryChannelHandler = AurumBatteryChannelHandler(this, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { methodChannel = it }
        methodChannel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSongs" -> {
                        try {
                            result.success(getSongs())
                        } catch (e: Exception) {
                            Log.e(TAG, "getSongs error", e)
                            result.error("GET_SONGS_ERROR", e.message, null)
                        }
                    }
                    "getSdkInt" -> {
                        result.success(Build.VERSION.SDK_INT)
                    }
                    "getDiagnosticLogPath" -> {
                        try {
                            val file = AurumDiagnosticLog.getLogFile(this)
                            result.success(if (file.exists()) file.absolutePath else null)
                        } catch (e: Exception) {
                            Log.e(TAG, "getDiagnosticLogPath error", e)
                            result.error("DIAG_LOG_ERROR", e.message, null)
                        }
                    }
                    "clearDiagnosticLog" -> {
                        AurumDiagnosticLog.clear(this)
                        result.success(null)
                    }
                    "logNetworkError" -> {
                        val ctx = call.argument<String>("context") ?: "unknown"
                        val msg = call.argument<String>("message") ?: ""
                        AurumDiagnosticLog.logNetworkError(ctx, msg)
                        result.success(null)
                    }
                    "openAutostartSettings" -> {
                        result.success(openAutostartSettings())
                    }

                "installApk" -> {
                    try {
                        val apkPath = call.argument<String>("path") ?: run { result.error("NO_PATH", "No path", null); return@setMethodCallHandler }
                        // FIX ("update install/uninstall jaisa lagta hai"):
                        // replaces the old ACTION_VIEW file-open flow with
                        // PackageInstaller's session API — see
                        // AurumSilentInstaller's doc comment for exactly
                        // why that flow could present as an uninstall
                        // prompt on some devices/failure paths, and why
                        // this categorically cannot. `result.success(null)`
                        // here just acknowledges the install was STARTED —
                        // the actual outcome (success/fail, possibly after
                        // the user taps through a confirmation screen)
                        // arrives later via the "onInstallResult" call back
                        // into Dart below, since PackageInstaller sessions
                        // are inherently async and can outlive this single
                        // method-channel round trip.
                        AurumSilentInstaller.install(this, apkPath) { success, message ->
                            runOnUiThread {
                                methodChannel?.invokeMethod(
                                    "onInstallResult",
                                    mapOf("success" to success, "message" to message)
                                )
                            }
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                "getAlbumArt" -> {
                        try {
                            val uri = call.argument<String>("uri")
                            if (uri.isNullOrEmpty()) {
                                result.success(null)
                                return@setMethodCallHandler
                            }
                            result.success(getAlbumArtBytes(uri))
                        } catch (e: Exception) {
                            Log.w(TAG, "getAlbumArt error", e)
                            result.success(null)
                        }
                    }
                "setStopOnTaskRemoved" -> {
                        // Mirrors AudioPrefs.stopOnSwipeNotifier so the native
                        // onTaskRemoved callback (a pure-Kotlin lifecycle hook
                        // with no Dart running when it actually fires) can
                        // honor the Settings → "Stop on Swipe from Recents"
                        // toggle. Written straight to the same SharedPreferences
                        // store Flutter uses (flutter.<key> prefix is how the
                        // shared_preferences plugin namespaces its keys) so
                        // AurumMediaSessionService can read it independently,
                        // even if this Activity's process was already killed.
                        try {
                            val value = call.argument<Boolean>("value") ?: false
                            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                                .edit()
                                .putBoolean("flutter.stop_on_swipe", value)
                                .apply()
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "setStopOnTaskRemoved error", e)
                            result.success(null)
                        }
                    }
                    "setHighRefreshRate" -> {
                        try {
                            val enabled = call.argument<Boolean>("enabled") ?: true
                            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                                .edit()
                                .putBoolean("flutter.high_refresh_rate", enabled)
                                .apply()
                            applyHighRefreshRate(enabled)
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "setHighRefreshRate error", e)
                            result.success(null)
                        }
                    }
                    "vibrateHaptic" -> {
                        try {
                            val amplitude = call.argument<Int>("amplitude") ?: 128
                            val durationMs = call.argument<Int>("durationMs") ?: 12
                            vibrateWithAmplitude(amplitude, durationMs.toLong())
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "vibrateHaptic error", e)
                            result.success(null)
                        }
                    }

                    // ---- Dynamic Island overlay (Settings -> Player toggle) ----
                    "checkOverlayPermission" -> {
                        result.success(hasOverlayPermission())
                    }
                    "requestOverlayPermission" -> {
                        try {
                            requestOverlayPermission()
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "requestOverlayPermission error", e)
                            result.error("OVERLAY_PERMISSION_ERROR", e.message, null)
                        }
                    }
                    "requestBatteryExemption" -> {
                        try {
                            requestBatteryExemption()
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "requestBatteryExemption error", e)
                            result.success(null)
                        }
                    }
                    "startIslandOverlay" -> {
                        try {
                            if (!hasOverlayPermission()) {
                                result.error("NO_OVERLAY_PERMISSION", "SYSTEM_ALERT_WINDOW not granted", null)
                                return@setMethodCallHandler
                            }
                            // Never draw the Island over Aurum's own UI: while the
                            // app is open (e.g. toggling it on in Settings) just
                            // report success — onStop() starts it the moment the
                            // app is minimized.
                            if (!appInForeground) {
                                startService(Intent(this, AurumIslandService::class.java))
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "startIslandOverlay error", e)
                            result.error("ISLAND_START_ERROR", e.message, null)
                        }
                    }
                    "stopIslandOverlay" -> {
                        try {
                            stopService(Intent(this, AurumIslandService::class.java))
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "stopIslandOverlay error", e)
                            result.success(null)
                        }
                    }
                    "updateIslandCustomization" -> {
                        // Settings -> Player's position/size/color controls
                        // call this on every change so a running overlay
                        // reflects the new value immediately (live preview)
                        // instead of only picking it up on the next
                        // pill<->expanded swap. No-op, safely, if the
                        // overlay isn't currently running.
                        try {
                            if (AurumIslandService.isRunning) {
                                AurumIslandService.refreshCustomizationNow()
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            Log.w(TAG, "updateIslandCustomization error", e)
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // Requests the display's highest available refresh rate for this
    // window (e.g. 90/120Hz on flagship panels) when enabled, or drops
    // back to the platform default when disabled. Settings → Appearance
    // → "High Refresh Rate" toggle drives this. Uses the modern
    // preferredDisplayModeId API on API 23+ (matches the exact Display.Mode
    // the panel actually supports, unlike the deprecated preferredRefreshRate
    // float which some OEM drivers silently ignore or round oddly) and
    // no-ops safely on anything older or on displays with only one mode.
    private fun applyHighRefreshRate(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        } ?: return

        if (!enabled) {
            window.attributes = window.attributes.apply { preferredDisplayModeId = 0 }
            return
        }
        try {
            val modes = display.supportedModes
            val currentMode = display.mode
            // Pick the highest-refresh-rate mode that keeps the same
            // resolution as the current mode — switching resolution too
            // would be a visible flicker/letterbox, not just a smoothness
            // change, so refresh rate is the only axis we optimize here.
            val best = modes
                .filter { it.physicalWidth == currentMode.physicalWidth &&
                          it.physicalHeight == currentMode.physicalHeight }
                .maxByOrNull { it.refreshRate }
            if (best != null) {
                window.attributes = window.attributes.apply { preferredDisplayModeId = best.modeId }
            }
        } catch (e: Exception) {
            Log.w(TAG, "applyHighRefreshRate error", e)
        }
    }

    // Cached lazily — getSystemService is cheap but there's no reason to
    // repeat the Build.VERSION branch on every single haptic tap, which on
    // a music app can fire dozens of times per minute (every button, every
    // swipe, every selection).
    private var cachedVibrator: Vibrator? = null
    private fun getVibrator(): Vibrator? {
        cachedVibrator?.let { return it }
        val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val mgr = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            mgr?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        cachedVibrator = v
        return v
    }

    /** Amplitude-controlled tap used for the Settings → Player → Haptic
     *  Intensity (Off / Light / Strong) preference. Flutter's built-in
     *  HapticFeedback.lightImpact()/mediumImpact() map to fixed OS haptic
     *  constants with no strength parameter, so "Light" vs "Strong" can't
     *  be expressed through that API at all — this bypasses it and drives
     *  the vibrator motor directly at a specific amplitude (1-255) instead.
     *  "Off" is handled entirely on the Dart side (AurumHaptics just
     *  doesn't call this method at all), so there's no near-zero-amplitude
     *  buzz to avoid here — every call that reaches this function is
     *  expected to actually vibrate. */
    private fun vibrateWithAmplitude(amplitude: Int, durationMs: Long) {
        val vibrator = getVibrator() ?: return
        if (!vibrator.hasVibrator()) return
        val clamped = amplitude.coerceIn(1, 255)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(durationMs, clamped))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(durationMs)
        }
    }

    private fun getSongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.SIZE,
        )
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.SIZE} >= $MIN_SIZE_BYTES"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} ASC"

        val cursor: Cursor? = contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection, selection, null, sortOrder
        )

        cursor?.use {
            val idCol       = it.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol    = it.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol   = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol    = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val albumIdCol  = it.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
            val durationCol = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val dataCol     = it.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)

            while (it.moveToNext()) {
                val id      = it.getLong(idCol)
                val albumId = it.getLong(albumIdCol)
                val artUri  = ContentUris.withAppendedId(ALBUM_ART_URI, albumId).toString()
                val contentUri = ContentUris.withAppendedId(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id
                ).toString()

                songs.add(mapOf(
                    "id"         to "local_$id",
                    "title"      to it.getString(titleCol),
                    "artist"     to (it.getString(artistCol) ?: "Unknown"),
                    "album"      to (it.getString(albumCol) ?: ""),
                    "artworkUrl" to artUri,
                    "localPath"  to it.getString(dataCol),
                    "contentUri" to contentUri,
                    "duration"   to (it.getLong(durationCol) / 1000).toInt(),
                ))
            }
        }
        Log.d(TAG, "Scanned ${songs.size} songs")
        return songs
    }

    private fun getAlbumArtBytes(uriString: String): ByteArray? {
        return try {
            val uri = Uri.parse(uriString)
            val bitmap: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    contentResolver.loadThumbnail(uri, android.util.Size(500, 500), null)
                } catch (e: Exception) {
                    Log.w(TAG, "loadThumbnail failed, falling back: ${e.message}")
                    openStreamAsBitmap(uri)
                }
            } else {
                openStreamAsBitmap(uri)
            }
            bitmap?.let { bmp ->
                ByteArrayOutputStream().use { out ->
                    bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    out.toByteArray()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getAlbumArtBytes failed for $uriString: ${e.message}")
            null
        }
    }

    // Opens OEM-specific "autostart/background allow" settings screen
    // (realme/OPPO/ColorOS, Xiaomi/MIUI, Vivo, Huawei, OnePlus, etc.).
    // Tries known component names one by one; falls back to the app's
    // own details page if none match/resolve on this device.
    private fun openAutostartSettings(): Boolean {
        val intents = listOf(
            Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerConsumptionActivity")),
            Intent().setComponent(ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
            Intent().setComponent(ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity")),
            Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
            Intent().setComponent(ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
            Intent().setComponent(ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
            Intent().setComponent(ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"))
        )
        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (packageManager.resolveActivity(intent, 0) != null) {
                    startActivity(intent)
                    return true
                }
            } catch (_: Exception) { /* try next */ }
        }
        // Fallback: app's own info page (Battery saver -> App details)
        return try {
            val fallback = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(fallback)
            true
        } catch (e: Exception) {
            Log.e(TAG, "openAutostartSettings fallback failed", e)
            false
        }
    }

    private fun bindMediaSessionService() {
        if (mediaSessionServiceConnection != null) return // already bound
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                // Nothing to do — AurumMediaSessionService.onGetSession()
                // handles exposing the MediaSession to any real
                // MediaController that connects (lock screen, Bluetooth,
                // Android Auto, etc). This binding's only job is to keep
                // the service alive and trigger its onCreate()/onBind() so
                // that MediaSession actually exists in the first place.
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                mediaSessionServiceConnection = null
            }
        }
        val intent = Intent(this, AurumMediaSessionService::class.java)
        // Both calls are needed: startService() keeps the service alive
        // independently of this Activity's lifecycle (so playback survives
        // the app being backgrounded/the Activity being destroyed);
        // bindService() is what actually triggers onCreate()/onBind()/
        // onGetSession() so the MediaSession comes into existence. Neither
        // call here carries the foreground-promotion 5-second deadline
        // that startForegroundService() does — that deadline is only
        // relevant to the startForeground() call AurumMediaSessionService
        // itself makes once real playback begins (see its Player.Listener).
        startService(intent)
        bindService(intent, connection, Context.BIND_AUTO_CREATE)
        mediaSessionServiceConnection = connection
    }

    // ---- Dynamic Island overlay permission plumbing ----------------------

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(this)
        } else {
            true
        }
    }

    // Opens the system's "Display over other apps" screen for this app.
    // Result is picked up passively — Dart re-checks checkOverlayPermission
    // when the Settings screen resumes (onResume/app-lifecycle on the Dart
    // side) rather than this Activity tracking an activity-result callback,
    // since the user can back out of this screen at any point and Dart's
    // own screen already needs to reflect the toggle's real state anyway.
    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val intent = Intent(
            android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName"),
        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        startActivity(intent)
    }

    // Battery optimization exemption — without this, some OEM battery
    // managers (same MIUI/ColorOS/etc. family openAutostartSettings()
    // already deals with) can freeze this process while backgrounded,
    // which would silently kill the overlay's WindowManager views even
    // though playback itself survives via the foreground MediaSessionService.
    @Suppress("BatteryLife")
    private fun requestBatteryExemption() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        if (powerManager.isIgnoringBatteryOptimizations(packageName)) return
        val intent = Intent(
            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        startActivity(intent)
    }

    private fun openStreamAsBitmap(uri: Uri): Bitmap? {
        val opts = BitmapFactory.Options().apply { inSampleSize = 2 }
        return contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, opts)
        }
    }

    // Auto Sleep Guard: registered/unregistered around the Activity's
    // visible lifetime (onStart/onStop) rather than held for the whole
    // process, since it only needs to catch unlocks while the app could
    // plausibly be looked at — a background-only session has no UI for
    // "activity" to mean anything for anyway, and playback continuing to
    // be silently guarded by the alarm doesn't depend on this receiver at
    // all (see AutoSleepGuard.recordActivity, called independently from
    // the player listener and in-app taps).
    private var screenUnlockReceiver: android.content.BroadcastReceiver? = null
    private var appInForeground = false

    override fun onStart() {
        super.onStart()
        appInForeground = true
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == Intent.ACTION_USER_PRESENT) {
                    AutoSleepGuard.recordActivity(ctx.applicationContext)
                }
            }
        }
        registerReceiver(receiver, android.content.IntentFilter(Intent.ACTION_USER_PRESENT))
        screenUnlockReceiver = receiver

        // App came to foreground — Island overlay would visually clash
        // with the real in-app now-playing UI, so hide it while the app
        // itself is visible. Re-shown in onStop() below when the app is
        // minimized/backgrounded again, same "app khud khulta hai to
        // overlay hide" behavior confirmed for the feature.
        if (AurumIslandService.isRunning) {
            stopService(Intent(this, AurumIslandService::class.java))
        }
    }

    override fun onStop() {
        appInForeground = false
        screenUnlockReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        screenUnlockReceiver = null

        // App minimized/backgrounded — restore the Island overlay if the
        // user has it enabled and a song is actually loaded. Dart mirrors
        // its own "Dynamic Island" toggle into this same SharedPreferences
        // store (flutter.island_enabled) so this native lifecycle hook can
        // decide on its own, without a live Dart isolate to ask.
        try {
            val islandEnabled = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.island_enabled", false)
            val hasSong = AurumMediaSessionService.sharedEngine?.player?.let {
                it.mediaItemCount > 0
            } ?: false
            if (islandEnabled && hasSong && hasOverlayPermission() && !AurumIslandService.isRunning) {
                startService(Intent(this, AurumIslandService::class.java))
            }
        } catch (e: Exception) {
            Log.w(TAG, "Island overlay restore on stop failed: ${e.message}")
        }

        super.onStop()
    }

    override fun onDestroy() {
        // Only stop the overlay here if playback itself isn't continuing
        // in the background — mirrors AurumMediaSessionService.onTaskRemoved's
        // own "actively playing" check, so swiping the app away while a
        // song is genuinely playing doesn't yank the Island out from under
        // a still-live session.
        val stillPlaying = AurumMediaSessionService.sharedEngine?.player?.let {
            it.isPlaying
        } ?: false
        if (!stillPlaying) {
            try { stopService(Intent(this, AurumIslandService::class.java)) } catch (_: Exception) {}
        }
        mediaSessionServiceConnection?.let {
            try { unbindService(it) } catch (_: Exception) {}
        }
        mediaSessionServiceConnection = null
        audioEngineChannelHandler?.release()
        audioEngineChannelHandler = null
        batteryChannelHandler?.release()
        batteryChannelHandler = null
        super.onDestroy()
    }
}
