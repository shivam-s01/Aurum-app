package com.aurum.music

import android.content.ContentUris
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.aurum.music/media_store"
        private const val TAG = "AurumMainActivity"

        // Album art content URI base
        private val ALBUM_ART_URI = Uri.parse("content://media/external/audio/albumart")

        // Minimum file size (500 KB) — filters out notification sounds, etc.
        private const val MIN_SIZE_BYTES = 500_000L
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

                    "getAlbumArt" -> {
                        try {
                            val uri = call.argument<String>("uri")
                            if (uri.isNullOrEmpty()) {
                                result.success(null)
                                return@setMethodCallHandler
                            }
                            result.success(getAlbumArtBytes(uri))
                        } catch (e: Exception) {
                            Log.e(TAG, "getAlbumArt error: ${e.message}")
                            result.success(null) // Return null, not error — UI shows placeholder
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ── MediaStore scan ───────────────────────────────────────────────────────

    private fun getSongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            @Suppress("DEPRECATION")
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,       // absolute file path
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.TRACK,      // track number (unused but useful)
        )

        // Only music files larger than MIN_SIZE_BYTES
        val selection =
            "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.SIZE} > $MIN_SIZE_BYTES"

        val sortOrder = "${MediaStore.Audio.Media.TITLE} ASC"

        val cursor: Cursor? = contentResolver.query(
            collection, projection, selection, null, sortOrder
        )

        cursor?.use { c ->
            val idCol      = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleCol   = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistCol  = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumCol   = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val albumIdCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
            val durCol     = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val dataCol    = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DATA)

            while (c.moveToNext()) {
                val id      = c.getLong(idCol)
                val albumId = c.getLong(albumIdCol)
                val dur     = c.getLong(durCol)       // milliseconds
                val path    = c.getString(dataCol) ?: ""

                // Sanitise title
                val rawTitle = c.getString(titleCol) ?: ""
                val title = rawTitle.ifEmpty { path.substringAfterLast('/').removeSuffix(".mp3") }

                // Sanitise artist — MediaStore sometimes returns "<unknown>"
                val rawArtist = c.getString(artistCol) ?: ""
                val artist = when {
                    rawArtist.isEmpty() || rawArtist == "<unknown>" -> "Unknown Artist"
                    else -> rawArtist
                }

                // Album art as content:// URI — Flutter side calls getAlbumArt to load bytes
                val artUri = ContentUris.withAppendedId(ALBUM_ART_URI, albumId).toString()

                songs.add(
                    mapOf(
                        "id"       to id.toString(),
                        "title"    to title,
                        "artist"   to artist,
                        "album"    to (c.getString(albumCol) ?: ""),
                        "duration" to dur.toString(),   // Flutter parses as int (ms)
                        "path"     to path,
                        "artwork"  to artUri,
                    )
                )
            }
        }

        Log.d(TAG, "Scanned ${songs.size} songs")
        return songs
    }

    // ── Album art bytes ───────────────────────────────────────────────────────

    private fun getAlbumArtBytes(uriString: String): ByteArray? {
        return try {
            val uri = Uri.parse(uriString)

            val bitmap: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // loadThumbnail is the modern, size-limited API (Android 10+)
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

    /** Decode a content/file URI as a Bitmap via an InputStream. */
    private fun openStreamAsBitmap(uri: Uri): Bitmap? {
        val opts = BitmapFactory.Options().apply {
            inSampleSize = 2 // downsample to ½ — enough for display
        }
        return contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream, null, opts)
        }
    }
}
