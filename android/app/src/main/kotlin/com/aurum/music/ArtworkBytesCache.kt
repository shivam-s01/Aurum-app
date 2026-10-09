package com.aurum.music

import android.util.LruCache
import java.net.URL

/**
 * Shared in-memory cache of downloaded artwork bytes (max ~6 MB) used by the
 * Dynamic Island and the home-screen widget. Both used to download the same
 * thumbnail again on every song change / refresh with no cache at all, so the
 * same image was fetched several times per song. Memory only, freed with the
 * process; failures return null exactly like the old inline downloads did.
 */
object ArtworkBytesCache {
    private val cache = object : LruCache<String, ByteArray>(6 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ByteArray): Int = value.size
    }

    fun fetch(urlString: String, connectTimeoutMs: Int, readTimeoutMs: Int): ByteArray? {
        cache.get(urlString)?.let { return it }
        val bytes = URL(urlString).openConnection().apply {
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
        }.getInputStream().use { it.readBytes() }
        if (bytes.isNotEmpty() && bytes.size < 2 * 1024 * 1024) cache.put(urlString, bytes)
        return bytes
    }
}
