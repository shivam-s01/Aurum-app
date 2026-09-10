package com.aurum.music

import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Embeds cover art into a downloaded MP3 file as an ID3v2.3 APIC frame,
 * with no external tagging library dependency (mp3agic/jaudiotagger would
 * each add several hundred KB to the APK for a single frame write).
 *
 * FIX ("song download ho ja raha hai lekin thumbnail ke sath download
 * nahi ho raha" — storage/file-manager/other music apps show no cover):
 * AurumMediaStoreDownloads.saveToPublicMusic() was always a byte-for-byte
 * copy of the raw downloaded audio — nothing anywhere in the download
 * pipeline (Dart DownloadProvider, this Kotlin channel, or
 * AurumMediaStoreDownloads itself) ever wrote artwork INTO the file
 * itself. The app's own UI never noticed because it always renders
 * artwork from the separate network artworkUrl kept in the Song model/
 * Hive record — completely independent of the actual MP3 bytes on disk.
 * Any other app reading the file directly (a file manager's thumbnail,
 * a different music player, Windows/macOS after USB transfer) only ever
 * sees what's embedded in the file's own ID3 tag, which was empty.
 *
 * This writes a minimal, single-frame ID3v2.3 tag containing only the
 * APIC (attached picture) frame — deliberately not a full tag rewrite
 * (title/artist/album), since the source stream may already carry its
 * own ID3 tag from the original encode that we don't want to clobber.
 * If an existing ID3v2 tag is present at the front of the file, this
 * inserts the APIC frame into it (rewriting only the tag header's size);
 * if not, it prepends a brand-new minimal tag. Either way the audio
 * frame data after the tag is never touched.
 */
object Id3ArtworkWriter {

    private const val TAG_ID = "ID3"
    private const val FRAME_ID_APIC = "APIC"

    /**
     * Embeds [artworkBytes] (raw JPEG/PNG bytes) as cover art into the MP3
     * at [file], in place. Returns true on success; on any failure the
     * original file is left completely untouched (never partially
     * written) and the caller should treat this as "no artwork embedded,
     * audio itself is still fine" rather than a download failure.
     */
    fun embedCoverArt(file: File, artworkBytes: ByteArray, mimeType: String = "image/jpeg"): Boolean {
        return try {
            val original = file.readBytes()
            val apicFrame = buildApicFrame(artworkBytes, mimeType)

            val existingTagSize = existingId3v2TagSize(original)
            val output = ByteArrayOutputStream(original.size + apicFrame.size + 64)

            if (existingTagSize > 0) {
                // Existing tag: keep its frames as-is, append our APIC frame,
                // and rewrite only the header's declared size to cover the
                // addition. Frame data itself (10-byte header already inside
                // apicFrame) is untouched by this — we're just growing the tag.
                val oldFrames = original.copyOfRange(10, existingTagSize)
                val newFramesSize = oldFrames.size + apicFrame.size

                output.write(TAG_ID.toByteArray(Charsets.ISO_8859_1))
                output.write(byteArrayOf(0x03, 0x00)) // version 2.3.0
                output.write(byteArrayOf(0x00))        // flags: none
                output.write(synchsafe(newFramesSize))
                output.write(oldFrames)
                output.write(apicFrame)
                output.write(original.copyOfRange(existingTagSize, original.size))
            } else {
                // No existing tag — prepend a fresh minimal ID3v2.3 tag
                // containing only our APIC frame.
                output.write(TAG_ID.toByteArray(Charsets.ISO_8859_1))
                output.write(byteArrayOf(0x03, 0x00))
                output.write(byteArrayOf(0x00))
                output.write(synchsafe(apicFrame.size))
                output.write(apicFrame)
                output.write(original)
            }

            file.writeBytes(output.toByteArray())
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Returns the total byte length of an existing ID3v2 tag at the start
     * of [bytes] (header + all frames), or 0 if the file doesn't start
     * with a recognizable "ID3" tag.
     */
    private fun existingId3v2TagSize(bytes: ByteArray): Int {
        if (bytes.size < 10) return 0
        if (bytes[0] != 'I'.code.toByte() || bytes[1] != 'D'.code.toByte() || bytes[2] != '3'.code.toByte()) {
            return 0
        }
        val size = unsynchsafe(bytes, 6)
        return if (size in 1..bytes.size) 10 + size else 0
    }

    /** ID3v2 sizes are "synchsafe": 4 bytes, 7 significant bits each. */
    private fun synchsafe(size: Int): ByteArray {
        return byteArrayOf(
            ((size ushr 21) and 0x7F).toByte(),
            ((size ushr 14) and 0x7F).toByte(),
            ((size ushr 7) and 0x7F).toByte(),
            (size and 0x7F).toByte(),
        )
    }

    private fun unsynchsafe(bytes: ByteArray, offset: Int): Int {
        return ((bytes[offset].toInt() and 0x7F) shl 21) or
            ((bytes[offset + 1].toInt() and 0x7F) shl 14) or
            ((bytes[offset + 2].toInt() and 0x7F) shl 7) or
            (bytes[offset + 3].toInt() and 0x7F)
    }

    /**
     * Builds a complete APIC frame (10-byte frame header + frame body)
     * per the ID3v2.3 spec: text encoding byte, null-terminated MIME
     * type, picture type byte (0x03 = front cover), null-terminated
     * description, then the raw image bytes.
     */
    private fun buildApicFrame(artworkBytes: ByteArray, mimeType: String): ByteArray {
        val body = ByteArrayOutputStream(artworkBytes.size + 32)
        body.write(0x00) // text encoding: ISO-8859-1
        body.write(mimeType.toByteArray(Charsets.ISO_8859_1))
        body.write(0x00) // MIME type terminator
        body.write(0x03) // picture type: front cover
        body.write(0x00) // empty description + terminator
        body.write(artworkBytes)

        val bodyBytes = body.toByteArray()
        val frame = ByteArrayOutputStream(bodyBytes.size + 10)
        frame.write(FRAME_ID_APIC.toByteArray(Charsets.ISO_8859_1))
        // Frame size uses plain big-endian (not synchsafe) in ID3v2.3,
        // unlike the outer tag header's size field.
        frame.write((bodyBytes.size ushr 24) and 0xFF)
        frame.write((bodyBytes.size ushr 16) and 0xFF)
        frame.write((bodyBytes.size ushr 8) and 0xFF)
        frame.write(bodyBytes.size and 0xFF)
        frame.write(byteArrayOf(0x00, 0x00)) // frame flags: none
        frame.write(bodyBytes)
        return frame.toByteArray()
    }
}
