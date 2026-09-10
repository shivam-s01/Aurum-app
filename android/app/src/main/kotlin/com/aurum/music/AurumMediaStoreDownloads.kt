package com.aurum.music

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File

/**
 * Saves finished song downloads into the device's PUBLIC Music library
 * (via MediaStore) instead of the app's private internal storage, and
 * deletes them from there too.
 *
 * FIX ("song download ekdam top level pe device mein save ho, file
 * manager/music app mein dikhe"): DownloadProvider (Dart side) was
 * writing finished downloads to getApplicationDocumentsDirectory()/downloads
 * — Android's app-private internal storage (/data/data/com.aurum.music/
 * app_flutter/downloads). That location is sandboxed to this app only:
 * it never appears in the device's file manager, in any other music app,
 * or via USB/MTP file browsing from a PC — which is exactly why saved
 * downloads looked like they were "not really saving to the device" even
 * though the app itself could still play them back.
 *
 * FIX ("delete karne pe file gayab hi nahi hoti"): the old delete path
 * called File(path).delete() directly on that private-storage file. Since
 * that's a normal file the app owns, a straightforward delete there
 * should generally succeed — but with downloads now living in the public
 * Music collection (below), a plain File.delete() no longer works at all
 * on Android 10+ (scoped storage requires going through MediaStore's own
 * ContentResolver.delete(uri) for anything the app didn't create via a
 * MediaStore insert), and — more importantly — the OLD delete() call's
 * return value was silently discarded, so a failed delete (locked file,
 * OEM storage quirk, stale/mismatched path) still went on to remove the
 * item from the in-app list, making the download disappear from Aurum
 * while the real file stayed on disk. deleteByMediaStore() below deletes
 * through the same ContentResolver API the file was inserted with — the
 * one reliable way to guarantee removal for a public-collection file —
 * and returns a real success/failure result instead of assuming success.
 *
 * Uses MediaStore.Audio.Media (RELATIVE_PATH = Music/Astra) on API 29+,
 * which is the correct, scoped-storage-safe way to place a file in the
 * public Music folder without needing WRITE_EXTERNAL_STORAGE or
 * MANAGE_EXTERNAL_STORAGE at all — no extra runtime permission prompt
 * needed for this specific case. Devices on API < 29 (pre-scoped-storage)
 * fall back to a direct File write into the real public Music directory,
 * which works fine pre-Android 10 with the legacy WRITE_EXTERNAL_STORAGE
 * permission already declared in the manifest.
 */
object AurumMediaStoreDownloads {

    private const val RELATIVE_DIR = "Music/Astra"

    /**
     * Copies [sourceFile] (a completed download sitting in the app's
     * private temp/cache location) into the public Music/Astra folder.
     * Returns the resulting MediaStore content URI as a String (API 29+)
     * or a plain file:// path (API < 29) — DownloadProvider persists
     * whichever is returned as the download's new localPath, and uses it
     * for both playback and later deletion.
     *
     * FIX ("thumbnail ke sath download nahi ho raha" — file saved fine
     * but carried no cover art visible outside the app): if [artworkBytes]
     * is supplied, it's embedded into [sourceFile] as an ID3v2 APIC frame
     * (see Id3ArtworkWriter) BEFORE the copy below, so the public copy —
     * and the private-storage fallback on failure — both carry real
     * embedded artwork any file manager/music app can show, not just
     * Aurum's own UI (which always drew artwork from the separate
     * network artworkUrl, never from the file itself). Embedding is
     * best-effort: a failure here never blocks the download, it just
     * means that one file ends up with no embedded art, exactly like
     * before this fix.
     *
     * On any failure, returns null — caller keeps the original private
     * file as a safe fallback (still playable in-app) rather than losing
     * the download entirely.
     */
    fun saveToPublicMusic(
        context: Context,
        sourceFile: File,
        displayName: String,
        mimeType: String = "audio/mpeg",
        artworkBytes: ByteArray? = null,
    ): String? {
        return try {
            if (artworkBytes != null && artworkBytes.isNotEmpty()) {
                Id3ArtworkWriter.embedCoverArt(sourceFile, artworkBytes)
                // Return value intentionally ignored — embedding is
                // best-effort and must never block the actual save below.
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                saveViaMediaStore(context, sourceFile, displayName, mimeType)
            } else {
                saveViaLegacyPublicDir(sourceFile, displayName)
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun saveViaMediaStore(
        context: Context,
        sourceFile: File,
        displayName: String,
        mimeType: String,
    ): String? {
        val resolver = context.contentResolver
        val collection = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
            put(MediaStore.Audio.Media.RELATIVE_PATH, RELATIVE_DIR)
            // Marks the file as "being written" so it's hidden from other
            // apps/gallery scans until IS_PENDING is cleared below — avoids
            // a half-written file showing up in some other music app mid-copy.
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }

        val itemUri = resolver.insert(collection, values) ?: return null

        // BUG FIX (found on recheck): if the copy throws partway through
        // (disk full, source file disappears, IO error), the exception was
        // previously left to propagate straight out of this function — the
        // outer saveToPublicMusic try/catch still caught it and correctly
        // returned null, but the MediaStore row created by insert() above
        // was never cleaned up. Since that row was left permanently stuck
        // at IS_PENDING=1, it would sit invisible and broken in MediaStore
        // forever (a phantom entry no app can see or remove through normal
        // means) every time a copy failed partway. Now the copy step has
        // its own try/catch that deletes the orphaned row before
        // re-raising, so a failed copy leaves no trace behind.
        try {
            resolver.openOutputStream(itemUri)?.use { out ->
                sourceFile.inputStream().use { input -> input.copyTo(out) }
            } ?: run {
                resolver.delete(itemUri, null, null)
                return null
            }
        } catch (e: Exception) {
            try { resolver.delete(itemUri, null, null) } catch (_: Exception) {}
            return null
        }

        // BUG FIX (found on second recheck): if update() here throws
        // (rare, but possible — resolver briefly disconnected, storage
        // hiccup), the exception falls through to saveToPublicMusic's
        // outer catch and this function returns null — but at this point
        // the file bytes are already fully copied into itemUri, just
        // still stuck at IS_PENDING=1. Without cleanup, that leaves a
        // complete-but-permanently-hidden duplicate copy in MediaStore
        // forever, on top of the original private-storage file the
        // caller keeps as its "fallback" — silently doubling storage
        // for that one song. Delete the stuck row here too so a failure
        // at this exact step behaves the same as every other failure
        // path in this function: nothing left behind.
        try {
            values.clear()
            values.put(MediaStore.Audio.Media.IS_PENDING, 0)
            resolver.update(itemUri, values, null, null)
        } catch (e: Exception) {
            try { resolver.delete(itemUri, null, null) } catch (_: Exception) {}
            return null
        }

        // Source file in private storage is no longer needed once the
        // public copy exists — remove it so the download doesn't exist
        // twice on disk (double storage usage for the same song).
        try { sourceFile.delete() } catch (_: Exception) {}

        return itemUri.toString()
    }

    private fun saveViaLegacyPublicDir(sourceFile: File, displayName: String): String? {
        val musicDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
            "Astra",
        )
        if (!musicDir.exists()) musicDir.mkdirs()
        val destFile = File(musicDir, displayName)
        try {
            sourceFile.copyTo(destFile, overwrite = true)
        } catch (e: Exception) {
            // Same orphan-cleanup fix as the MediaStore path: don't leave a
            // partially-written file behind on a failed copy.
            try { if (destFile.exists()) destFile.delete() } catch (_: Exception) {}
            return null
        }
        try { sourceFile.delete() } catch (_: Exception) {}
        return destFile.absolutePath
    }

    /**
     * Deletes a song previously saved via [saveToPublicMusic]. Accepts
     * either a MediaStore content:// URI string (API 29+ path) or a plain
     * file path (API < 29 / legacy path) and returns true only if the
     * underlying file/row is actually confirmed gone — callers must not
     * remove the download from their own list unless this returns true,
     * or a failed delete will silently leave an orphaned file on disk
     * while the app believes it's been removed.
     */
    fun delete(context: Context, pathOrUri: String): Boolean {
        return try {
            if (pathOrUri.startsWith("content://")) {
                val uri = Uri.parse(pathOrUri)
                val rows = context.contentResolver.delete(uri, null, null)
                rows > 0
            } else {
                val f = File(pathOrUri)
                if (!f.exists()) true // already gone — treat as success
                else f.delete()
            }
        } catch (e: Exception) {
            false
        }
    }

    /** True if [pathOrUri] still resolves to an existing file/row. */
    fun exists(context: Context, pathOrUri: String): Boolean {
        return try {
            if (pathOrUri.startsWith("content://")) {
                val uri = Uri.parse(pathOrUri)
                context.contentResolver.openInputStream(uri)?.use { true } ?: false
            } else {
                File(pathOrUri).exists()
            }
        } catch (e: Exception) {
            false
        }
    }
}
