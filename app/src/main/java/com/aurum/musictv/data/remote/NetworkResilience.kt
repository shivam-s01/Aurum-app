package com.aurum.musictv.data.remote

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import kotlinx.coroutines.delay

/**
 * Small, dependency-free helpers used by AurumApi to make every network
 * call resilient instead of "works on good wifi, silently fails on a
 * flaky TV box connection". Three things live here:
 *   1. isOnline() — a real connectivity check (not just "did OkHttp throw"),
 *      so the UI can show "You're offline" instead of a generic error.
 *   2. retryWithBackoff() — retries transient failures (timeouts, 5xx,
 *      DNS blips) with exponential backoff + jitter, capped so a broken
 *      endpoint fails fast instead of hanging the UI forever.
 *   3. EdgeCache — a tiny in-memory TTL cache keyed by URL, so repeated
 *      calls to the same home-section queries within a short window don't
 *      re-hit the Worker (which itself is backed by Cloudflare's edge
 *      cache) — this is the client-side half of that same idea.
 */
object NetworkResilience {

    /** App-wide "are we online right now" check. Cheap, synchronous,
     *  safe to call before every network attempt. */
    fun isOnline(context: Context): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true // fail open — don't block playback attempts on a broken check
        val network = cm.activeNetwork ?: return false
        val capabilities = cm.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    /**
     * Retries [block] up to [maxAttempts] times on failure (either an
     * exception or a null/false result per [isSuccess]), with exponential
     * backoff starting at [initialDelayMs] and doubling each time up to
     * [maxDelayMs]. Small random jitter avoids every failed request on a
     * flaky network retrying in lockstep.
     */
    suspend fun <T> retryWithBackoff(
        maxAttempts: Int = 3,
        initialDelayMs: Long = 400,
        maxDelayMs: Long = 4000,
        isSuccess: (T) -> Boolean = { it != null },
        block: suspend (attempt: Int) -> T,
    ): T {
        var delayMs = initialDelayMs
        var lastResult: T? = null
        repeat(maxAttempts) { attempt ->
            val result = try {
                block(attempt)
            } catch (e: Exception) {
                null
            }
            @Suppress("UNCHECKED_CAST")
            if (result != null && isSuccess(result as T)) return result
            lastResult = result
            if (attempt < maxAttempts - 1) {
                val jitter = (delayMs * 0.2 * Math.random()).toLong()
                delay(delayMs + jitter)
                delayMs = (delayMs * 2).coerceAtMost(maxDelayMs)
            }
        }
        @Suppress("UNCHECKED_CAST")
        return lastResult as T
    }

    /** Simple in-memory TTL cache. Not persisted across process death by
     *  design — this is for smoothing repeated calls within one app
     *  session (e.g. re-opening Search with the same query, Home
     *  refreshing), not an offline store.
     *
     *  Hard-capped at [MAX_ENTRIES]: on a 1GB-RAM TV box, an unbounded
     *  cache of every search query ever typed would slowly eat memory the
     *  video/audio pipeline needs. Each entry is a List<Song> (small —
     *  just strings/urls, no bitmaps; those live in Coil's own capped
     *  cache), but count still needs a ceiling for a box that may run for
     *  days without a process restart. LRU eviction via access-order
     *  LinkedHashMap — oldest-unused entry drops first once the cap hits. */
    object EdgeCache {
        private const val MAX_ENTRIES = 40

        private data class Entry(val value: Any?, val expiresAtMs: Long)
        private val store = object : LinkedHashMap<String, Entry>(MAX_ENTRIES, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?): Boolean =
                size > MAX_ENTRIES
        }

        @Synchronized
        fun <T> get(key: String): T? {
            val entry = store[key] ?: return null
            if (System.currentTimeMillis() > entry.expiresAtMs) {
                store.remove(key)
                return null
            }
            @Suppress("UNCHECKED_CAST")
            return entry.value as? T
        }

        @Synchronized
        fun put(key: String, value: Any?, ttlMs: Long) {
            store[key] = Entry(value, System.currentTimeMillis() + ttlMs)
        }

        @Synchronized
        fun clear() = store.clear()
    }
}
