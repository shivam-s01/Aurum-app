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

            // FIX round 2 ("YouTube ka song download pe bilkul play nahi
            // ho raha" — same corruption bug, different container): round
            // 1 only blacklisted the MP4 "ftyp" signature, since that
            // covered JioSaavn's downloads. But YouTube downloads go
            // through YoutubeInnertube.resolve(), which picks the
            // highest-averageBitrate audio stream with NO container
            // filter — on the overwhelming majority of videos that's
            // itag 251, WebM/Opus, not MP4 at all. WebM starts with an
            // EBML magic number (0x1A45DFA3), which the ftyp-only check
            // never matched, so this writer kept right on prepending an
            // MP3-only ID3v2 tag onto WebM files too — same box/container
            // corruption as before, just under a different format name.
            // Blacklisting containers one at a time will always be one
            // step behind whatever format shows up next (Saavn or
            // YouTube could both start serving Ogg/FLAC/anything
            // tomorrow). Flip to a WHITELIST instead: only proceed if the
            // bytes actually look like a real MP3 elementary stream —
            // either an existing ID3v2 header, or a valid MPEG audio
            // frame sync (0xFF followed by a byte whose top 3 bits are
            // all 1). Anything else is left completely untouched.
            val looksLikeMp3 =
                (original.size >= 3 &&
                    original[0] == 'I'.code.toByte() &&
                    original[1] == 'D'.code.toByte() &&
                    original[2] == '3'.code.toByte()) ||
                (original.size >= 2 &&
                    (original[0].toInt() and 0xFF) == 0xFF &&
                    (original[1].toInt() and 0xE0) == 0xE0)

            if (looksLikeMp3) {
                embedIntoMp3(file, original, artworkBytes, mimeType)
            } else {
                // FIX round 3 ("thumbnail ke sath download bhi ho, Astra
                // ki branding kharab na ho" — market-facing ask): rounds
                // 1-2 made this writer safe by skipping MP4/WebM entirely
                // rather than corrupting them, but "safe" there meant "no
                // embedded art at all" for JioSaavn's MP4 downloads (the
                // majority of downloads in this app). MP4 CAN carry real
                // cover art — via an iTunes-style moov/udta/meta/ilst/covr
                // box, never an ID3 frame — but writing one is only safe
                // if inserting those bytes cannot shift any sample data
                // that a `stco`/`co64` chunk-offset table already points
                // to. See embedIntoMp4Safely() below for exactly which
                // layout qualifies and why every other case still just
                // skips (same safe no-op as before, never corrupts).
                // WebM (YouTube's usual container) has no equivalently
                // simple/safe insertion point without a real EBML writer,
                // so it still skips — no regression there, just no new
                // capability yet.
                embedIntoMp4Safely(file, original, artworkBytes, mimeType)
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun embedIntoMp3(file: File, original: ByteArray, artworkBytes: ByteArray, mimeType: String): Boolean {
        return try {
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

    // ─────────────────────────────────────────────────────────────
    // MP4 cover art (iTunes-style moov/udta/meta/hdlr/ilst/covr/data)
    // ─────────────────────────────────────────────────────────────
    //
    // WHY THIS HAS TO BE THIS CAREFUL: an MP4's sample-to-file mapping
    // is a table of absolute byte offsets (`stco`/`co64` boxes, nested
    // inside moov/trak/.../stbl) that point directly into `mdat`. If we
    // insert ANY bytes before `mdat`, every one of those offsets is now
    // wrong by the inserted length, and the file plays back garbled or
    // not at all — patching every stco/co64 entry correctly is real
    // MP4-muxer work, not something to bolt on here. The one insertion
    // that is unconditionally safe without touching a single offset:
    // appending new bytes to the very END of `moov`, and ONLY when
    // `moov` itself comes AFTER `mdat` in the file. In that layout,
    // `mdat` (and everything stco/co64 point at) is already finished
    // and untouched by anything we do afterward — we're just making the
    // trailing `moov` box bigger. If `moov` comes BEFORE `mdat` instead
    // (the other common MP4 layout, used for network "fast start"),
    // that safety guarantee doesn't hold, so this bails out and embeds
    // nothing — same safe no-op as before, never a corrupt file.
    private fun embedIntoMp4Safely(file: File, original: ByteArray, artworkBytes: ByteArray, mimeType: String): Boolean {
        return try {
            val boxes = readTopLevelBoxes(original) ?: return false
            val moov = boxes.firstOrNull { it.type == "moov" } ?: return false
            val mdat = boxes.firstOrNull { it.type == "mdat" } ?: return false

            // Unsafe layout (moov before mdat) — see class-level reasoning
            // above. Skip rather than risk touching sample offsets.
            if (moov.offset < mdat.offset) return false

            // Don't touch a file that already has metadata we haven't
            // parsed — safer to skip than to risk a malformed duplicate
            // udta/meta structure sitting alongside an existing one.
            val moovChildren = readTopLevelBoxes(
                original.copyOfRange(moov.offset + 8, moov.offset + moov.size)
            ) ?: return false
            if (moovChildren.any { it.type == "udta" }) return false

            val typeIndicator = if (mimeType.contains("png", ignoreCase = true)) 14 else 13
            val dataPayload = ByteArrayOutputStream(artworkBytes.size + 8).apply {
                write(byteArrayOf(0x00, 0x00, 0x00, typeIndicator.toByte())) // version(0) + flags(type)
                write(byteArrayOf(0x00, 0x00, 0x00, 0x00))                   // locale, reserved
                write(artworkBytes)
            }.toByteArray()
            val dataBox = mp4Box("data", dataPayload)
            val covrBox = mp4Box("covr", dataBox)
            val ilstBox = mp4Box("ilst", covrBox)

            val hdlrPayload = ByteArrayOutputStream(32).apply {
                write(byteArrayOf(0x00, 0x00, 0x00, 0x00)) // version + flags
                write(byteArrayOf(0x00, 0x00, 0x00, 0x00)) // predefined
                write("mdir".toByteArray(Charsets.US_ASCII)) // handler_type
                write(ByteArray(12))                         // reserved
                write(0x00)                                  // empty name
            }.toByteArray()
            val hdlrBox = mp4Box("hdlr", hdlrPayload)

            val metaPayload = ByteArrayOutputStream(hdlrBox.size + ilstBox.size + 4).apply {
                write(byteArrayOf(0x00, 0x00, 0x00, 0x00)) // version + flags
                write(hdlrBox)
                write(ilstBox)
            }.toByteArray()
            val metaBox = mp4Box("meta", metaPayload)
            val udtaBox = mp4Box("udta", metaBox)

            val insertAt = moov.offset + moov.size
            val output = ByteArrayOutputStream(original.size + udtaBox.size)
            output.write(original, 0, insertAt)
            output.write(udtaBox)
            output.write(original, insertAt, original.size - insertAt)
            val result = output.toByteArray()

            // Patch moov's own declared size (4-byte BE at its own start)
            // to include the udta box we just appended as its new child.
            val newMoovSize = moov.size + udtaBox.size
            result[moov.offset] = ((newMoovSize ushr 24) and 0xFF).toByte()
            result[moov.offset + 1] = ((newMoovSize ushr 16) and 0xFF).toByte()
            result[moov.offset + 2] = ((newMoovSize ushr 8) and 0xFF).toByte()
            result[moov.offset + 3] = (newMoovSize and 0xFF).toByte()

            file.writeBytes(result)
            true
        } catch (e: Exception) {
            false
        }
    }

    private data class Mp4Box(val type: String, val offset: Int, val size: Int)

    /**
     * Walks a flat sequence of ISO-BMFF boxes starting at offset 0 of
     * [bytes] (works for both top-level file boxes and a box's own
     * children, since both are just concatenated [size][type][payload]
     * entries). Returns null if a 64-bit extended-size (size field == 1)
     * or to-EOF (size field == 0) box is encountered — both are valid
     * MP4 but rare for these short audio-only downloads, and neither is
     * needed for the safe-layout check above; bailing out just means
     * "skip embedding," never a corrupt read.
     */
    private fun readTopLevelBoxes(bytes: ByteArray): List<Mp4Box>? {
        val boxes = mutableListOf<Mp4Box>()
        var pos = 0
        while (pos + 8 <= bytes.size) {
            val size = ((bytes[pos].toInt() and 0xFF) shl 24) or
                ((bytes[pos + 1].toInt() and 0xFF) shl 16) or
                ((bytes[pos + 2].toInt() and 0xFF) shl 8) or
                (bytes[pos + 3].toInt() and 0xFF)
            if (size < 8 || pos + size > bytes.size) return null
            val type = String(bytes, pos + 4, 4, Charsets.US_ASCII)
            boxes.add(Mp4Box(type, pos, size))
            pos += size
        }
        return boxes
    }

    private fun mp4Box(type: String, payload: ByteArray): ByteArray {
        val size = payload.size + 8
        val box = ByteArrayOutputStream(size)
        box.write((size ushr 24) and 0xFF)
        box.write((size ushr 16) and 0xFF)
        box.write((size ushr 8) and 0xFF)
        box.write(size and 0xFF)
        box.write(type.toByteArray(Charsets.US_ASCII))
        box.write(payload)
        return box.toByteArray()
    }
}
