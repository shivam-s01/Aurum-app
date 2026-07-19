package com.aurum.musictv.sync

import com.aurum.musictv.data.model.LikedSongRow
import com.aurum.musictv.data.model.PlaybackStateRow
import com.aurum.musictv.data.model.ProfileRow
import com.aurum.musictv.data.model.QueueRow
import com.aurum.musictv.data.model.RecentlyPlayedRow
import com.aurum.musictv.data.model.Song
import com.aurum.musictv.data.model.SongDto
import com.aurum.musictv.data.model.toDto
import com.aurum.musictv.data.model.toSong
import com.aurum.musictv.data.remote.SupabaseClientProvider
import io.github.jan.supabase.postgrest.from
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json

/**
 * The one place TV talks to Supabase for anything beyond auth. Deliberately
 * thin: no local cache/database on TV (per the "TV stores almost nothing
 * locally" requirement) — every read goes to Supabase, every write goes
 * straight through. This is fine at Aurum's scale (single-user reads on a
 * TV screen, not a high-throughput service) and keeps the APK small (no
 * Room/SQLDelight dependency).
 */
object SyncRepository {

    private val json = Json { ignoreUnknownKeys = true }

    private val userId: String?
        get() = SupabaseClientProvider.auth.currentUserOrNull()?.id

    // ── Continue Listening / now-playing handoff ────────────────────────

    /** Push current playback position so mobile can pick up where TV left
     *  off (and vice versa). Call this periodically (every ~5s) during
     *  playback and once on pause/stop — never on every position tick, to
     *  avoid hammering Postgrest for something the user can't perceive
     *  sub-5-second precision on anyway. */
    suspend fun pushPlaybackState(song: Song, positionMs: Long, isPlaying: Boolean) {
        val uid = userId ?: return
        runCatching {
            SupabaseClientProvider.postgrest.from("playback_state").upsert(
                PlaybackStateRow(
                    userId = uid,
                    songId = song.id,
                    songData = song.toDto(),
                    positionMs = positionMs,
                    isPlaying = isPlaying,
                    device = "tv",
                )
            )
        }
    }

    suspend fun fetchPlaybackState(): PlaybackStateRow? {
        val uid = userId ?: return null
        return runCatching {
            SupabaseClientProvider.postgrest.from("playback_state")
                .select { filter { eq("user_id", uid) } }
                .decodeSingleOrNull<PlaybackStateRow>()
        }.getOrNull()
    }

    /** Polls playback_state every 8s for changes from mobile — used to show
     *  a "Playing on phone — Resume here?" style banner. Deliberately
     *  polling, not a Realtime websocket subscription: a single-user TV
     *  screen doesn't need sub-second sync, and an always-open socket +
     *  its background dispatcher is measurable RAM/battery overhead on a
     *  1GB RAM box for a feature the user glances at occasionally. 8s is
     *  imperceptible for a "resume from phone" banner.
     *
     *  [isActive] gates the network call itself, not just what happens
     *  with the result — while it returns false (e.g. Home isn't the
     *  visible screen) this loop does nothing but sleep, zero requests
     *  fired, zero CPU/radio wakeup. */
    fun observePlaybackState(
        scope: CoroutineScope,
        isActive: () -> Boolean = { true },
    ): Flow<PlaybackStateRow> = flow {
        var lastSongId: String? = null
        var lastPositionMs: Long? = null
        while (true) {
            if (isActive()) {
                val row = fetchPlaybackState()
                if (row != null && (row.songId != lastSongId || row.positionMs != lastPositionMs)) {
                    lastSongId = row.songId
                    lastPositionMs = row.positionMs
                    emit(row)
                }
            }
            delay(8_000)
        }
    }

    // ── Queue ─────────────────────────────────────────────────────────────

    suspend fun pushQueue(items: List<Song>, currentIndex: Int) {
        val uid = userId ?: return
        runCatching {
            SupabaseClientProvider.postgrest.from("playback_queue").upsert(
                QueueRow(userId = uid, items = items.map { it.toDto() }, currentIndex = currentIndex)
            )
        }
    }

    suspend fun fetchQueue(): QueueRow? {
        val uid = userId ?: return null
        return runCatching {
            SupabaseClientProvider.postgrest.from("playback_queue")
                .select { filter { eq("user_id", uid) } }
                .decodeSingleOrNull<QueueRow>()
        }.getOrNull()
    }

    // ── Premium status (read-only on TV — see profiles table RLS) ──────

    suspend fun fetchIsPremium(): Boolean {
        val uid = userId ?: return false
        return runCatching {
            SupabaseClientProvider.postgrest.from("profiles")
                .select { filter { eq("user_id", uid) } }
                .decodeSingleOrNull<ProfileRow>()
                ?.isPremium ?: false
        }.getOrDefault(false)
    }

    /** Polls the premium flag every 30s — flips shortly after a purchase
     *  completes on mobile, no TV restart needed. 30s is fine here: even
     *  Spotify-style cross-device premium unlocks aren't instant, and this
     *  avoids a second always-open socket alongside playback polling.
     *  Same [isActive] gate as [observePlaybackState] — no request fired
     *  while Home isn't the visible screen. */
    fun observeIsPremium(
        scope: CoroutineScope,
        isActive: () -> Boolean = { true },
    ): Flow<Boolean> = flow {
        var last: Boolean? = null
        while (true) {
            if (isActive()) {
                val premium = fetchIsPremium()
                if (premium != last) {
                    last = premium
                    emit(premium)
                }
            }
            delay(30_000)
        }
    }

    // ── Recently played (fire-and-forget, mirrors mobile's history) ────

    suspend fun logRecentlyPlayed(song: Song) {
        val uid = userId ?: return
        runCatching {
            SupabaseClientProvider.postgrest.from("recently_played").insert(
                mapOf(
                    "user_id" to uid,
                    "song_id" to song.id,
                    "song_data" to json.encodeToString(SongDto.serializer(), song.toDto()),
                )
            )
        }
    }

    /** Most recent distinct plays for the "Recently Played" / "Jump Back
     *  In" home rows — same table [logRecentlyPlayed] writes to. Sorting
     *  and de-duplication happen client-side (not via a postgrest
     *  order()/limit() DSL call) since this row count is small (a few
     *  dozen at most) and it keeps this call using the exact same
     *  select{filter{...}} shape already proven elsewhere in this file. */
    suspend fun fetchRecentlyPlayed(limit: Int = 20): List<Song> {
        val uid = userId ?: return emptyList()
        return runCatching {
            SupabaseClientProvider.postgrest.from("recently_played")
                .select { filter { eq("user_id", uid) } }
                .decodeList<RecentlyPlayedRow>()
                .asReversed() // insert() appends, so latest is last
                .distinctBy { it.songId }
                .take(limit)
                .mapNotNull { it.songData?.toSong() }
        }.getOrDefault(emptyList())
    }

    /** Distinct liked songs — backs the "Liked Songs" home row and the
     *  Library tab. Same client-side-ordering rationale as
     *  [fetchRecentlyPlayed] above. */
    suspend fun fetchLikedSongs(limit: Int = 50): List<Song> {
        val uid = userId ?: return emptyList()
        return runCatching {
            SupabaseClientProvider.postgrest.from("liked_songs")
                .select { filter { eq("user_id", uid) } }
                .decodeList<LikedSongRow>()
                .asReversed()
                .take(limit)
                .mapNotNull { it.songData?.toSong() }
        }.getOrDefault(emptyList())
    }

    suspend fun likeSong(song: Song) {
        val uid = userId ?: return
        runCatching {
            SupabaseClientProvider.postgrest.from("liked_songs").upsert(
                LikedSongRow(userId = uid, songId = song.id, songData = song.toDto())
            )
        }
    }

    suspend fun unlikeSong(songId: String) {
        val uid = userId ?: return
        runCatching {
            SupabaseClientProvider.postgrest.from("liked_songs").delete {
                filter { eq("user_id", uid); eq("song_id", songId) }
            }
        }
    }

    /** Single-song existence check for the Player screen's heart icon —
     *  avoids pulling the entire liked_songs list just to know one
     *  boolean. Cheap indexed lookup on (user_id, song_id). */
    suspend fun isSongLiked(songId: String): Boolean {
        val uid = userId ?: return false
        return runCatching {
            SupabaseClientProvider.postgrest.from("liked_songs")
                .select { filter { eq("user_id", uid); eq("song_id", songId) } }
                .decodeList<LikedSongRow>()
                .isNotEmpty()
        }.getOrDefault(false)
    }
}
