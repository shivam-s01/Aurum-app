package com.aurum.music

/** Mirrors lib/models/song.dart's Song class — only fields the engine needs. */
data class NativeSong(
    val id: String,
    val title: String,
    val artist: String,
    val album: String,
    val artworkUrl: String,
    val source: String,       // "saavn" | "youtube" | "local"
    val isLocal: Boolean,
    val localPath: String?,
)

/**
 * Resolves a playable stream URL for a song. Backed by a MethodChannel call
 * into Dart's ApiService.resolveStreamUrl (JioSaavn/YouTube fallback chain
 * stays in Dart for Stage 2 — porting that chain itself is Stage 4).
 * Must be a real suspend function so a superseded call can be cancelled by
 * cancelling its coroutine Job (I7) — not just ignored client-side.
 */
interface StreamResolver {
    suspend fun resolve(song: NativeSong, forceRefresh: Boolean = false): String?
    suspend fun invalidate(song: NativeSong)
}
