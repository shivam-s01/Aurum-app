package com.aurum.musictv

import android.app.Application
import coil.Coil
import coil.ImageLoader
import coil.disk.DiskCache
import coil.memory.MemoryCache

/**
 * Configures Coil's global ImageLoader with hard caps tuned for 1GB-RAM
 * Android TV boxes. Coil's defaults size the memory cache off the
 * device's total RAM (up to 25% of it) — on a phone that's reasonable,
 * but on a 1GB box that's ~250MB just for image bitmaps, which starves
 * the video/audio pipeline and every other allocation. We cap it hard
 * instead of trusting the percentage-of-RAM default.
 */
class AurumTvApp : Application() {

    override fun onCreate() {
        super.onCreate()

        val imageLoader = ImageLoader.Builder(this)
            .memoryCache {
                MemoryCache.Builder(this)
                    // Hard cap, not a percentage of device RAM. ~24MB is
                    // enough for a couple of screens' worth of 300x300
                    // downsampled album art without ever approaching the
                    // point where the OS starts killing background work.
                    .maxSizeBytes(24 * 1024 * 1024)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("aurum_image_cache"))
                    // Small disk budget too — 8GB total storage means
                    // every MB spent on a disk image cache is a MB not
                    // available for the OS, other apps, or future song
                    // caching. 40MB is plenty for TV-card thumbnails.
                    .maxSizeBytes(40 * 1024 * 1024)
                    .build()
            }
            // Bitmaps are already downsampled to card size at load time
            // (see SongCardPresenter), so RGB_565 halves per-pixel memory
            // vs the ARGB_8888 default with no visible quality loss for
            // small TV thumbnails.
            .bitmapConfig(android.graphics.Bitmap.Config.RGB_565)
            .build()

        Coil.setImageLoader(imageLoader)
    }

    /** 1GB-RAM TV boxes hit memory pressure far more often than phones —
     *  when the OS signals it (background, low, or critical), drop
     *  everything reclaimable that isn't needed for current playback:
     *  Coil's in-memory bitmap cache and the search EdgeCache. Both
     *  rebuild cheaply from network/disk, so this is a pure memory
     *  give-back with no correctness cost — and it's exactly the kind of
     *  cooperative behavior that keeps Android from killing the whole
     *  process (and audio playback with it) under pressure. */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            Coil.imageLoader(this).memoryCache?.clear()
            com.aurum.musictv.data.remote.NetworkResilience.EdgeCache.clear()
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        Coil.imageLoader(this).memoryCache?.clear()
        com.aurum.musictv.data.remote.NetworkResilience.EdgeCache.clear()
    }
}
