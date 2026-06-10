package com.aurum.music

import android.content.ContentUris
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.aurum.music/media_store"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSongs" -> {
                        try {
                            result.success(getSongs())
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getSongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

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

        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.SIZE} > 500000"
        val sortOrder = "${MediaStore.Audio.Media.TITLE} ASC"

        val cursor: Cursor? = contentResolver.query(
            collection, projection, selection, null, sortOrder
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

                val artUri = ContentUris.withAppendedId(
                    Uri.parse("content://media/external/audio/albumart"), albumId
                ).toString()

                songs.add(
                    mapOf(
                        "id"       to id.toString(),
                        "title"    to (it.getString(titleCol) ?: "Unknown"),
                        "artist"   to (it.getString(artistCol) ?: "Unknown Artist"),
                        "album"    to (it.getString(albumCol) ?: ""),
                        "duration" to it.getLong(durationCol).toString(),
                        "path"     to (it.getString(dataCol) ?: ""),
                        "artwork"  to artUri,
                    )
                )
            }
        }

        return songs
    }
}
