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
    private var audioEngineChannelHandler: AurumEngineChannelHandler? = null

    // Owns the native Shorts video engine (search+resolve+ExoPlayer
    // pool) — fully separate from the audio engine/main queue above.
    private var shortsChannelHandler: AurumShortsChannelHandler? = null

    // Exposes YoutubeInnertube.getRelated() (YouTube's own related-videos
    // graph) to Dart for use as a getAutoQueue signal — fully separate
    // channel from audio engine playback commands and Shorts, see
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

    // NOTE: We intentionally do NOT use androidx.core.splashscreen's
    // installSplashScreen() here. On several OEM skins (MIUI, OxygenOS,
    // etc.) it forces the launcher icon to render inside a light/white
    // "icon card" on the Android 12+ system splash regardless of any
    // background/icon-background color set in styles.xml, and it also
    // interferes with the status bar's edge-to-edge transparency that
    // Flutter sets up in main.dart. Falling back to the plain
    // launch_background.xml + dark LaunchTheme (no SplashScreen API
    // involvement at all) avoids both issues consistently across devices.
    // The system splash is then just a flat dark frame for ~1 cold-start
    // frame, immediately replaced by Flutter's own UI — including our
    // _A_ + AURUM animation in splash_screen.dart.

    override fun onCreate(savedInstanceState: Bundle?) {
        // FIX (gray/white screen flash on cold start, swipe-down full-player
        // dismiss, and back-navigation): AndroidManifest.xml pins this
        // Activity to LaunchTheme permanently — NormalTheme (correct dark
        // windowBackground) was defined in styles.xml but never actually
        // applied anywhere. LaunchTheme's static launch_background drawable
        // was staying as the WINDOW's background for the Activity's entire
        // life, not just the splash instant. Every time the Android window
        // surface gets recreated/redrawn before Flutter's next frame is
        // composited (cold start, and any full-screen surface change like a
        // route transition or the full player's swipe-to-dismiss), the OS
        // briefly shows that stale window background — which is what read
        // as a gray flash. Must be called BEFORE super.onCreate() so it
        // takes effect before the window is first created.
        setTheme(R.style.NormalTheme)
        super.onCreate(savedInstanceState)
        // Apply the saved High Refresh Rate preference immediately at
        // launch — without this, the setting would only take effect after
        // the user re-opens Settings and toggles it again post-launch,
        // since Flutter's own setHighRefreshRate call only fires from the
        // Settings screen, not on cold start.
        val enabled = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.high_refresh_rate", true)
        applyHighRefreshRate(enabled)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioEngineChannelHandler = AurumEngineChannelHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        bindMediaSessionService()

        // Native Shorts engine (audio-only 30s clips — no video
        // surface/PlatformView anymore; visible layer is always the
        // artwork on the Dart side).
        val shortsHandler = AurumShortsChannelHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        shortsChannelHandler = shortsHandler

        relatedChannelHandler = AurumRelatedChannelHandler(flutterEngine.dartExecutor.binaryMessenger)

        batteryChannelHandler = AurumBatteryChannelHandler(this, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
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
                    "openAutostartSettings" -> {
                        result.success(openAutostartSettings())
                    }

                "installApk" -> {
                    try {
                        val apkPath = call.argument<String>("path") ?: run { result.error("NO_PATH", "No path", null); return@setMethodCallHandler }
                        val file = java.io.File(apkPath)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this,
                            "${packageName}.fileprovider",
                            file
                        )
                        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
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

    override fun onStart() {
        super.onStart()
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                if (intent.action == Intent.ACTION_USER_PRESENT) {
                    AutoSleepGuard.recordActivity(ctx.applicationContext)
                }
            }
        }
        registerReceiver(receiver, android.content.IntentFilter(Intent.ACTION_USER_PRESENT))
        screenUnlockReceiver = receiver
    }

    override fun onStop() {
        screenUnlockReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        screenUnlockReceiver = null
        super.onStop()
    }

    override fun onDestroy() {
        mediaSessionServiceConnection?.let {
            try { unbindService(it) } catch (_: Exception) {}
        }
        mediaSessionServiceConnection = null
        audioEngineChannelHandler?.release()
        audioEngineChannelHandler = null
        shortsChannelHandler?.engine?.release()
        shortsChannelHandler = null
        batteryChannelHandler?.release()
        batteryChannelHandler = null
        super.onDestroy()
    }
}
