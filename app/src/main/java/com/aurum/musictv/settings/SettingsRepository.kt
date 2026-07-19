package com.aurum.musictv.settings

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class AudioQuality(val label: String, val bitrateKbps: Int) {
    LOW("Low (96 kbps)", 96),
    NORMAL("Normal (160 kbps)", 160),
    HIGH("High (320 kbps)", 320),
}

enum class AppLanguage(val label: String, val tag: String) {
    ENGLISH("English", "en"),
    HINDI("हिंदी", "hi"),
}

/**
 * Local-only preferences: SharedPreferences, not Room/SQLDelight — this
 * is a handful of scalar settings, a real database is dead weight for
 * that on a 1GB-RAM box (per the "TV stores almost nothing locally"
 * project requirement, same reasoning as SyncRepository's no-local-cache
 * design). Backed by a StateFlow so SettingsScreen recomposes live
 * without polling.
 */
class SettingsRepository private constructor(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("aurum_tv_settings", Context.MODE_PRIVATE)

    private val _audioQuality = MutableStateFlow(loadAudioQuality())
    val audioQuality: StateFlow<AudioQuality> = _audioQuality.asStateFlow()

    private val _language = MutableStateFlow(loadLanguage())
    val language: StateFlow<AppLanguage> = _language.asStateFlow()

    private val _ampledDarkTheme = MutableStateFlow(prefs.getBoolean(KEY_AMOLED, true))
    val amoledTheme: StateFlow<Boolean> = _ampledDarkTheme.asStateFlow()

    private fun loadAudioQuality(): AudioQuality {
        val name = prefs.getString(KEY_QUALITY, AudioQuality.NORMAL.name)
        return runCatching { AudioQuality.valueOf(name ?: AudioQuality.NORMAL.name) }
            .getOrDefault(AudioQuality.NORMAL)
    }

    private fun loadLanguage(): AppLanguage {
        val tag = prefs.getString(KEY_LANGUAGE, AppLanguage.ENGLISH.tag)
        return AppLanguage.entries.firstOrNull { it.tag == tag } ?: AppLanguage.ENGLISH
    }

    fun setAudioQuality(quality: AudioQuality) {
        prefs.edit().putString(KEY_QUALITY, quality.name).apply()
        _audioQuality.value = quality
    }

    fun setLanguage(language: AppLanguage) {
        prefs.edit().putString(KEY_LANGUAGE, language.tag).apply()
        _language.value = language
    }

    fun setAmoledTheme(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_AMOLED, enabled).apply()
        _ampledDarkTheme.value = enabled
    }

    /** Returns the freed byte count so the caller can show it. Deletes
     *  Coil's on-disk image cache directory only — there's no local song
     *  cache on TV to worry about (see SyncRepository kdoc: every read
     *  goes straight to Supabase, nothing else is cached to disk). */
    fun clearImageCache(context: Context): Long {
        val dir = context.applicationContext.cacheDir.resolve("aurum_image_cache")
        val freed = dirSizeBytes(dir)
        dir.deleteRecursively()
        return freed
    }

    private fun dirSizeBytes(dir: java.io.File): Long {
        if (!dir.exists()) return 0L
        return dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }

    companion object {
        private const val KEY_QUALITY = "audio_quality"
        private const val KEY_LANGUAGE = "app_language"
        private const val KEY_AMOLED = "amoled_theme"

        @Volatile private var instance: SettingsRepository? = null

        fun get(context: Context): SettingsRepository =
            instance ?: synchronized(this) {
                instance ?: SettingsRepository(context).also { instance = it }
            }
    }
}
