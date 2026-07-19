package com.aurum.musictv.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "aurum_tv_settings")

enum class AppTheme { DARK, AMOLED, MIDNIGHT_VIOLET }
enum class AudioQuality { LOW, NORMAL, HIGH, LOSSLESS_IF_AVAILABLE }

data class AppSettings(
    val theme: AppTheme = AppTheme.AMOLED,
    val audioQuality: AudioQuality = AudioQuality.HIGH,
    val autoplay: Boolean = true,
    val crossfadeSeconds: Int = 4,
    val normalizeVolume: Boolean = true,
)

/**
 * Single source of truth for every Settings-screen toggle, backed by
 * Jetpack DataStore (replaces the old no-op SharedPreferences pattern —
 * this one is actually read by PlayerManager/AurumApi, not just written
 * and forgotten). All reads are a Flow so any screen reacts live if a
 * setting changes elsewhere (e.g. crossfade changed while a song is
 * mid-playback).
 */
object SettingsStore {
    private val KEY_THEME = stringPreferencesKey("theme")
    private val KEY_AUDIO_QUALITY = stringPreferencesKey("audio_quality")
    private val KEY_AUTOPLAY = booleanPreferencesKey("autoplay")
    private val KEY_CROSSFADE_SECONDS = intPreferencesKey("crossfade_seconds")
    private val KEY_NORMALIZE_VOLUME = booleanPreferencesKey("normalize_volume")

    fun observe(context: Context): Flow<AppSettings> =
        context.dataStore.data.map { prefs ->
            AppSettings(
                theme = prefs[KEY_THEME]?.let { runCatching { AppTheme.valueOf(it) }.getOrNull() }
                    ?: AppTheme.AMOLED,
                audioQuality = prefs[KEY_AUDIO_QUALITY]?.let { runCatching { AudioQuality.valueOf(it) }.getOrNull() }
                    ?: AudioQuality.HIGH,
                autoplay = prefs[KEY_AUTOPLAY] ?: true,
                crossfadeSeconds = prefs[KEY_CROSSFADE_SECONDS] ?: 4,
                normalizeVolume = prefs[KEY_NORMALIZE_VOLUME] ?: true,
            )
        }

    suspend fun setTheme(context: Context, theme: AppTheme) {
        context.dataStore.edit { it[KEY_THEME] = theme.name }
    }

    suspend fun setAudioQuality(context: Context, quality: AudioQuality) {
        context.dataStore.edit { it[KEY_AUDIO_QUALITY] = quality.name }
    }

    suspend fun setAutoplay(context: Context, enabled: Boolean) {
        context.dataStore.edit { it[KEY_AUTOPLAY] = enabled }
    }

    suspend fun setCrossfadeSeconds(context: Context, seconds: Int) {
        context.dataStore.edit { it[KEY_CROSSFADE_SECONDS] = seconds }
    }

    suspend fun setNormalizeVolume(context: Context, enabled: Boolean) {
        context.dataStore.edit { it[KEY_NORMALIZE_VOLUME] = enabled }
    }

    /** Snapshot read for one-off use (e.g. PlayerManager deciding crossfade
     *  at the moment a track ends) without collecting a Flow. */
    suspend fun snapshot(context: Context): AppSettings {
        var result = AppSettings()
        observe(context).collectFirstInto { result = it }
        return result
    }

    private suspend fun Flow<AppSettings>.collectFirstInto(onEach: (AppSettings) -> Unit) {
        kotlinx.coroutines.flow.first { onEach(it); true }
    }
}
