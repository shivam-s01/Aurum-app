package com.aurum.musictv.settings

import android.content.Context
import android.os.Build
import com.aurum.musictv.data.remote.NetworkResilience
import java.io.File

/** Read-only facts shown on the "Device Info" and "About" rows. */
object DeviceInfo {
    fun appVersion(context: Context): String = runCatching {
        val pInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        pInfo.versionName ?: "1.0.0"
    }.getOrDefault("1.0.0")

    fun deviceModel(): String = "${Build.MANUFACTURER} ${Build.MODEL}"

    fun androidVersion(): String = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})"

    /** Human-readable size of Coil's disk cache + this app's cache dir, so
     *  "Clear Cache" shows the user what they're about to free up. */
    fun cacheSizeLabel(context: Context): String {
        val bytes = dirSize(context.cacheDir)
        val mb = bytes / (1024.0 * 1024.0)
        return if (mb < 1) "< 1 MB" else "%.1f MB".format(mb)
    }

    private fun dirSize(dir: File): Long {
        if (!dir.exists()) return 0L
        return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }

    /** Clears the app's disk cache dir (image cache lives here via Coil's
     *  default disk cache) plus the in-memory network EdgeCache, so
     *  "Clear Cache" in Settings actually frees space instead of being
     *  cosmetic. */
    fun clearCache(context: Context) {
        runCatching { context.cacheDir.deleteRecursively() }
        NetworkResilience.EdgeCache.clear()
    }
}
