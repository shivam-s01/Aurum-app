package com.aurum.musictv.data.remote

import com.aurum.musictv.data.model.Song
import com.aurum.musictv.data.model.SongSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * TV-side port of lib/services/api_service.dart, kept intentionally small:
 * only search, home sections, and stream resolution. No lyrics, no
 * recommendation-engine calls, no offline queue splicing — those stay
 * phone-only for now. Same Worker backend, so zero backend changes needed.
 */
object AurumApi {

    // Same Worker URL as the phone app (lib/services/api_service.dart:209).
    private const val WORKER = "https://aurum-worker.shivamsharma962122.workers.dev"

    /** Last raw diagnostic captured from a search() call — surfaced by
     *  HomeBrowseFragment's Toast so on-device failures are debuggable
     *  without logcat access. Not thread-safe by design; this is a
     *  single-user single-screen TV app, last-write-wins is fine here. */
    var lastDiagnostic: String = ""
        private set

    // Timeouts tuned for flaky TV-box wifi: connect fails fast (so a dead
    // network surfaces quickly instead of hanging the UI), read is a bit
    // longer to tolerate the Worker's own cold-start / upstream latency.
    // retryOnConnectionFailure handles low-level socket retries; the
    // higher-level NetworkResilience.retryWithBackoff (used in search/
    // resolveStreamUrl below) handles retrying on empty/failed *results*,
    // which OkHttp's own retry can't do.
    //
    // dispatcher.maxRequests capped at 6: OkHttp defaults to 64 in-flight
    // requests, sized for phone/desktop-class devices. On a 1GB-RAM TV
    // box that's needless thread/socket overhead sitting idle most of
    // the time; 6 comfortably covers this app's real peak (homeSections'
    // own semaphore already caps parallel search calls at 3) while still
    // letting a stream resolve overlap a search without queuing.
    private val client = OkHttpClient.Builder()
        .connectTimeout(6, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .connectionPool(okhttp3.ConnectionPool(4, 60, TimeUnit.SECONDS))
        .dispatcher(
            okhttp3.Dispatcher().apply {
                maxRequests = 6
                maxRequestsPerHost = 6
            }
        )
        .build()

    private suspend fun getJson(url: String): JSONObject? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url(url).build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val body = resp.body?.string() ?: return@withContext null
                JSONObject(body)
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Live search used by the Search screen and Home's query rotation.
     *  Wrapped in retryWithBackoff so one dropped packet on TV wifi
     *  doesn't surface as "No results" — and short-cached via EdgeCache
     *  so typing-then-backspacing-then-retyping the same query within a
     *  few seconds doesn't refire the network call. Results are re-ranked
     *  client-side by [rankByRelevance] before returning, since the raw
     *  Worker/Saavn order is not always the best match for what the user
     *  actually typed. */
    suspend fun search(query: String, limit: Int = 25): List<Song> {
        val cacheKey = "search:$query:$limit"
        NetworkResilience.EdgeCache.get<List<Song>>(cacheKey)?.let { return it }

        val encoded = java.net.URLEncoder.encode(query, "UTF-8")
        val songs = NetworkResilience.retryWithBackoff(
            maxAttempts = 3,
            isSuccess = { it: List<Song> -> it.isNotEmpty() },
        ) {
            // Worker's real route is /result/?query=&limit= (see
            // aurum-worker src/index.js router) — NOT /api/search/songs,
            // which 404s.
            val results = getJsonArrayOrObjectData("$WORKER/result/?query=$encoded&limit=$limit")
            val ranked = rankByRelevance(parseSongs(results), query)
            // Drop obvious non-song uploads (full movies, jukeboxes,
            // reaction videos etc. — see isLikelySong) before ranking is
            // final. Fails open: if filtering would wipe out the whole
            // result set (e.g. the user is deliberately searching for
            // "bollywood jukebox"), keep the unfiltered results rather
            // than showing nothing — an imperfect result beats an empty
            // screen.
            val filtered = ranked.filter { isLikelySong(it) }
            if (filtered.isNotEmpty()) filtered else ranked
        }
        if (songs.isNotEmpty()) {
            NetworkResilience.EdgeCache.put(cacheKey, songs, ttlMs = 60_000)
        }
        return songs
    }

    /**
     * Re-scores raw search results against the query text so an exact or
     * near-exact title match always lands above a loosely-related result
     * the backend happened to rank higher — the "algorithm" layer search
     * was missing (previously just showed results in whatever order
     * Saavn/the Worker returned them).
     *
     * Scoring, highest first: exact title match (100) > title starts
     * with query (85) > every query word present in title (70) > exact
     * artist match, e.g. searching an artist's name directly (55) > every
     * query word present in artist (45) > title contains the query as a
     * substring (30) > most query words present across title+artist —
     * catches typos/partial words like "arjit" for "Arijit" (15) > no
     * textual match at all, i.e. backend-only "related" result (0). Ties
     * keep the original backend order (stable sort) so same-tier results
     * don't get needlessly shuffled.
     */
    private fun rankByRelevance(songs: List<Song>, query: String): List<Song> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return songs
        val queryWords = q.split(Regex("\\s+")).filter { it.isNotBlank() }

        fun score(song: Song): Int {
            val title = song.title.lowercase()
            val artist = song.artist.lowercase()
            val titleWordHits = queryWords.count { w -> title.split(Regex("\\s+")).any { it.startsWith(w) || w.startsWith(it) } }
            return when {
                title == q -> 100
                title.startsWith(q) -> 85
                queryWords.isNotEmpty() && queryWords.all { title.contains(it) } -> 70
                artist == q -> 55
                queryWords.isNotEmpty() && queryWords.all { artist.contains(it) } -> 45
                title.contains(q) -> 30
                queryWords.isNotEmpty() && titleWordHits >= (queryWords.size + 1) / 2 -> 15
                else -> 0
            }
        }

        return songs
            .withIndex()
            .sortedWith(compareByDescending<IndexedValue<Song>> { score(it.value) }.thenBy { it.index })
            .map { it.value }
    }

    /**
     * Filters out results that are textually relevant but aren't
     * actually a single song — this is the accuracy layer that keeps
     * "Sad Songs" from showing a movie upload or a 2-hour lofi loop just
     * because the title matched. Two signals, both cheap (no extra
     * network call):
     *
     *   1. Duration: real single tracks land roughly 45s–12min. Below
     *      that is usually a short/teaser/ringtone; above it is almost
     *      always a jukebox, full album, "full movie", or a looped
     *      1-hour mix. `durationSec == 0` (duration unknown, some
     *      YouTube results omit it) is let through rather than dropped —
     *      failing closed there would filter out perfectly good songs
     *      just because the field is missing.
     *   2. Title keywords: catches the common non-song upload patterns
     *      text-search alone can't distinguish from a real song title —
     *      "full movie", "jukebox" (a whole-album playlist video),
     *      "live concert"/"reaction", "episode", "trailer".
     */
    private fun isLikelySong(song: Song): Boolean {
        val duration = song.durationSec
        if (duration in 1..44) return false
        if (duration > 720) return false // > 12 minutes

        val title = song.title.lowercase()
        val junkPhrases = listOf(
            "full movie", "full video song", "jukebox", "audio jukebox",
            "live concert", "reaction", "full episode", "trailer",
            "official trailer", "interview", "making of", "behind the scenes",
            "compilation", "1 hour loop", "one hour loop", "8d audio mix",
            "unboxing", "vlog",
        )
        if (junkPhrases.any { title.contains(it) }) return false

        return true
    }

    /** Worker responses come back in one of two shapes depending on
     *  endpoint/route: {"data": [...]} or a bare [...] array. This also
     *  records exactly what happened (HTTP code, body snippet, or
     *  exception) into lastDiagnostic instead of silently swallowing
     *  failures — the previous version returned an empty JSONArray() on
     *  every failure path with no way to tell network error apart from
     *  empty-but-successful response apart from parse failure. */
    private suspend fun getJsonArrayOrObjectData(url: String): JSONArray {
        return withContext(Dispatchers.IO) {
            try {
                val req = Request.Builder().url(url).build()
                client.newCall(req).execute().use { resp ->
                    val code = resp.code
                    if (!resp.isSuccessful) {
                        lastDiagnostic = "HTTP $code from $url"
                        return@withContext JSONArray()
                    }
                    val body = resp.body?.string()
                    if (body.isNullOrBlank()) {
                        lastDiagnostic = "Empty body (HTTP $code) from $url"
                        return@withContext JSONArray()
                    }
                    val trimmed = body.trimStart()
                    val array = if (trimmed.startsWith("[")) {
                        JSONArray(body)
                    } else {
                        val obj = JSONObject(body)
                        // Worker's /result/ route replies as
                        // {"success":true,"data":{"results":[...]}}, so check
                        // data.results before falling back to a bare
                        // data:[...] shape (used by other worker routes).
                        obj.optJSONObject("data")?.optJSONArray("results")
                            ?: obj.optJSONArray("data")
                            ?: JSONArray()
                    }
                    if (array.length() == 0) {
                        lastDiagnostic = "Parsed 0 items. Body snippet: " +
                            body.take(200)
                    } else {
                        lastDiagnostic = "OK: ${array.length()} items"
                    }
                    array
                }
            } catch (e: Exception) {
                lastDiagnostic = "Exception: ${e.javaClass.simpleName}: ${e.message}"
                JSONArray()
            }
        }
    }

    // Each section has a POOL of queries instead of one fixed query — every
    // homeSections() call picks a different one per section, so "Bollywood
    // Hits" isn't the literal same 15 songs every time the user opens the
    // app or hits refresh. Pools stay on-topic per row (no query bleed
    // between "Love Songs" and "Party Mix") so the row's title still makes
    // sense no matter which query in its pool got picked.
    private val sectionPools: List<Pair<String, List<String>>> = listOf(
        "Trending Now" to listOf(
            "trending 2026", "trending songs this week", "viral songs 2026", "top trending hindi",
        ),
        "New Releases" to listOf(
            "new songs 2026", "latest bollywood releases", "new hindi songs this month", "fresh releases 2026",
        ),
        "Made For You" to listOf(
            "top hits playlist", "popular hindi songs", "most played songs", "hit songs collection",
        ),
        "Top Charts" to listOf(
            "top charts", "billboard hindi hits", "top 50 bollywood", "chartbusters 2026",
        ),
        "Bollywood Hits" to listOf(
            "bollywood hits", "bollywood blockbuster songs", "bollywood dance hits", "bollywood romantic hits",
        ),
        "Love Songs" to listOf(
            "love songs hits", "romantic hindi songs", "unplugged love songs", "80s 90s romantic hits",
        ),
        "Party Mix" to listOf(
            "party dance hits", "dj remix songs", "wedding dance songs", "club hits hindi",
        ),
        "Punjabi Beats" to listOf(
            "punjabi songs 2026", "punjabi bhangra hits", "new punjabi songs",
        ),
        "Retro Classics" to listOf(
            "90s bollywood classics", "old is gold hindi", "kishore kumar hits", "lata mangeshkar hits",
        ),
        "Sad & Soulful" to listOf(
            "sad songs hindi", "heartbreak songs", "soulful hindi songs",
        ),
    )

    /** Fresh, randomized every call: which sections show up, what order,
     *  and which query within each section's pool — all reshuffled.
     *
     *  8 of the 10 pools render per load (was 5) — a premium music TV
     *  home page reads as sparse with only 5 rows; 8 fills the screen
     *  properly without pulling in literally every pool (which would
     *  make near-duplicate/thin categories more likely to show up
     *  together). Each row now fetches 18 songs (was 12) so scrolling a
     *  row doesn't run out after a few seconds of D-pad holds. Fetches
     *  still capped at concurrency 3 — more rows means more total calls,
     *  but not more *simultaneous* ones, so this doesn't add CPU/network
     *  pressure at any single instant, just spreads more of it over the
     *  same throttle.
     *
     *  Each row mixes sources: search() returns Saavn results, then
     *  [mixInYoutube] blends in a handful of YouTube results for the
     *  same query and interleaves them — so a "Bollywood Hits" row is
     *  genuinely both YT + Saavn, not just Saavn with a YouTube-shaped
     *  fallback that only kicks in on failure. */
    suspend fun homeSections(): List<Pair<String, List<Song>>> = kotlinx.coroutines.coroutineScope {
        val chosenPools = sectionPools.shuffled().take(8)
        val semaphore = kotlinx.coroutines.sync.Semaphore(3)
        val deferred = chosenPools.map { (title, pool) ->
            kotlinx.coroutines.async {
                semaphore.withPermit {
                    val query = pool.random()
                    val saavnSongs = search(query, limit = 18)
                    val mixed = mixInYoutube(saavnSongs, query)
                    title to mixed
                }
            }
        }
        deferred.map { it.await() }.filter { (_, songs) -> songs.isNotEmpty() }
    }

    /**
     * Blends a few YouTube results for [query] into [saavnSongs] so home
     * rows aren't single-source. Interleaved roughly every 3rd slot
     * (Saavn, Saavn, Saavn, YouTube, ...) rather than appended at the end
     * — an all-YouTube tail would never be seen on rows the user doesn't
     * scroll all the way through. Capped at 4 YouTube tracks per row to
     * keep this cheap: it's one extra network call per row, not per
     * song, and YouTube resolve is heavier than Saavn's direct
     * downloadUrl (see resolveStreamUrl), so keeping the ratio Saavn-
     * majority keeps typical taps cheap to resolve.
     *
     * Results are passed through [isLikelySong] first — YouTube search is
     * pure text-match with no concept of "is this actually a song", so
     * without filtering, a "Sad Songs" row could just as easily pull in
     * a 40-minute reaction video, a full-movie upload, or a live stream
     * that happens to share keywords with the query. That's exactly the
     * kind of wrong-category result a premium row can't have.
     */
    private suspend fun mixInYoutube(saavnSongs: List<Song>, query: String): List<Song> {
        if (saavnSongs.isEmpty()) return saavnSongs
        val ytSongs = runCatching { searchYoutubeFallback(query, limit = 8) }
            .getOrDefault(emptyList())
            .filter { isLikelySong(it) }
            .take(4)
        if (ytSongs.isEmpty()) return saavnSongs

        val result = mutableListOf<Song>()
        var ytIndex = 0
        saavnSongs.forEachIndexed { i, song ->
            result.add(song)
            if ((i + 1) % 3 == 0 && ytIndex < ytSongs.size) {
                result.add(ytSongs[ytIndex])
                ytIndex++
            }
        }
        // Any leftover YT songs that didn't get an interleave slot (short
        // Saavn list) still get appended, so the mix isn't lost entirely.
        while (ytIndex < ytSongs.size) {
            result.add(ytSongs[ytIndex])
            ytIndex++
        }
        return result
    }

    /**
     * Resolves a playable stream URL right before playback. This is the
     * exact spot that used to cause "click nahi ho raha" — if Saavn's
     * downloadUrl was missing/expired, this returned null and PlayerManager
     * would silently no-op with nothing playing and no error shown.
     *
     * Now: (1) each attempt is retried with backoff instead of giving up
     * on one flaky response, and (2) if the song's own source fails after
     * retries, we fall back to searching YouTube for the same
     * title+artist and resolving THAT instead of giving up — so almost
     * every tap results in something playing.
     */
    suspend fun resolveStreamUrl(song: Song): String? = withContext(Dispatchers.IO) {
        val direct = NetworkResilience.retryWithBackoff(
            maxAttempts = 2,
            isSuccess = { it: String? -> !it.isNullOrBlank() },
        ) {
            resolveDirect(song)
        }
        if (!direct.isNullOrBlank()) return@withContext direct

        // Direct source failed twice — fall back to YouTube search using
        // title + artist, same as the phone app's fallback chain. This is
        // what turns a dead Saavn link into a still-playable tap instead
        // of a silent no-op.
        lastDiagnostic = "Primary source failed for '${song.title}', falling back to YouTube"
        val fallbackQuery = "${song.title} ${song.artist}".trim()
        val ytResults = runCatching { searchYoutubeFallback(fallbackQuery) }.getOrNull()
        val ytSong = ytResults?.firstOrNull() ?: return@withContext null
        resolveDirect(ytSong.copy(source = SongSource.YOUTUBE))
    }

    private suspend fun resolveDirect(song: Song): String? = when (song.source) {
        SongSource.YOUTUBE -> {
            val proxyUrl = "$WORKER/api/yt-proxy?id=${song.id}"
            val probeOk = try {
                val probe = Request.Builder()
                    .url(proxyUrl)
                    .header("Range", "bytes=0-255")
                    .build()
                client.newCall(probe).execute().use { r -> r.isSuccessful || r.code == 206 }
            } catch (_: Exception) { false }
            if (probeOk) {
                proxyUrl
            } else {
                val streamJson = getJson("$WORKER/api/yt-stream?id=${song.id}")
                streamJson?.optString("url")?.takeIf { it.isNotBlank() }
            }
        }
        SongSource.SAAVN -> {
            val json = getJson("$WORKER/api/songs?ids=${song.id}")
            val data = json?.optJSONArray("data")?.optJSONObject(0)
            data?.optString("downloadUrl")?.takeIf { it.isNotBlank() }
                ?: song.streamUrl
        }
        SongSource.LOCAL -> song.streamUrl
    }

    /** Worker's search endpoint is Saavn-first; for the fallback chain we
     *  need actual YouTube results, so this hits the Worker's YouTube
     *  search route directly instead of reusing search() (which is
     *  Saavn-shaped parsing). Empty on any failure — this is itself the
     *  last-resort path, there's no further fallback beyond it. */
    private suspend fun searchYoutubeFallback(query: String, limit: Int = 3): List<Song> {
        val encoded = java.net.URLEncoder.encode(query, "UTF-8")
        val json = getJson("$WORKER/api/yt-search?query=$encoded&limit=$limit") ?: return emptyList()
        val arr = json.optJSONArray("data") ?: json.optJSONArray("results") ?: return emptyList()
        val out = mutableListOf<Song>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id").ifBlank { o.optString("videoId") }
            if (id.isBlank()) continue
            out.add(
                Song(
                    id = id,
                    title = o.optString("title", query),
                    artist = o.optString("artist").ifBlank { o.optString("channel", "Unknown Artist") },
                    albumArtUrl = o.optString("thumbnail").ifBlank { null },
                    durationSec = o.optInt("duration", 0),
                    source = SongSource.YOUTUBE,
                )
            )
        }
        return out
    }

    data class PairingSession(val code: String, val confirmUrl: String, val expiresInSeconds: Int)

    /** Starts a new TV<->phone pairing session. Worker generates a short
     *  code + stores it in KV; TV shows it as a QR of confirmUrl. */
    suspend fun createPairingSession(): PairingSession? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url("$WORKER/api/pair/create")
                .post(ByteArray(0).toRequestBody(null))
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val body = resp.body?.string() ?: return@withContext null
                val json = JSONObject(body)
                if (!json.optBoolean("success")) return@withContext null
                PairingSession(
                    code = json.optString("code"),
                    confirmUrl = json.optString("confirmUrl"),
                    expiresInSeconds = json.optInt("expiresInSeconds", 120),
                )
            }
        } catch (e: Exception) {
            null
        }
    }

    /** Polls pairing status. Returns the Google idToken once the phone has
     *  confirmed sign-in, null while still pending/expired. */
    suspend fun pollPairingStatus(code: String): String? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url("$WORKER/api/pair/$code/status").build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val body = resp.body?.string() ?: return@withContext null
                val json = JSONObject(body)
                if (json.optString("status") == "approved") {
                    json.optString("idToken").takeIf { it.isNotBlank() }
                } else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun parseSongs(arr: JSONArray): List<Song> {
        val out = mutableListOf<Song>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val id = o.optString("id")
            if (id.isBlank()) continue
            val title = o.optString("song")
                .ifBlank { o.optString("name") }
                .ifBlank { o.optString("title", "Unknown") }
            val artist = extractArtist(o)
            val artUrl = extractArtwork(o)
            val duration = o.optInt("duration", 0)
            out.add(
                Song(
                    id = id,
                    title = title,
                    artist = artist,
                    albumArtUrl = artUrl,
                    durationSec = duration,
                    source = SongSource.SAAVN,
                )
            )
        }
        return out
    }

    private fun extractArtist(o: JSONObject): String {
        val artistsField = o.optJSONObject("artists")
        val primary = artistsField?.optJSONArray("primary")
        if (primary != null && primary.length() > 0) {
            val names = mutableListOf<String>()
            for (i in 0 until primary.length()) {
                val a = primary.optJSONObject(i)
                val name = a?.optString("name")?.takeIf { it.isNotBlank() }
                if (name != null) names.add(name)
            }
            if (names.isNotEmpty()) return names.joinToString(", ")
        }
        return o.optString("primary_artists")
            .ifBlank { o.optString("singers") }
            .ifBlank { o.optString("artist") }
            .ifBlank { "Unknown Artist" }
    }

    private fun extractArtwork(o: JSONObject): String? {
        val imageField = o.opt("image")
        if (imageField is JSONArray && imageField.length() > 0) {
            val last = imageField.optJSONObject(imageField.length() - 1)
            return last?.optString("url") ?: last?.optString("link")
        }
        // aurum-worker's /result/ route sends "image" as a plain string
        // (already resized to 500x500), not the phone app's array-of-sizes
        // shape — handle that directly instead of falling through to the
        // artwork/thumbnail fields, which the worker never sets.
        if (imageField is String && imageField.isNotBlank()) return imageField
        return o.optString("artwork").ifBlank { null }
            ?: o.optString("thumbnail").ifBlank { null }
    }
}
