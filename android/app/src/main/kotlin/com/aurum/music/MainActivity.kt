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
import android.os.IBinder
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioEngineChannelHandler = AurumEngineChannelHandler(this, flutterEngine.dartExecutor.binaryMessenger)
        bindMediaSessionService()

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
                    else -> result.notImplemented()
                }
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

    override fun onDestroy() {
        mediaSessionServiceConnection?.let {
            try { unbindService(it) } catch (_: Exception) {}
        }
        mediaSessionServiceConnection = null
        audioEngineChannelHandler?.release()
        audioEngineChannelHandler = null
        super.onDestroy()
    }
}
