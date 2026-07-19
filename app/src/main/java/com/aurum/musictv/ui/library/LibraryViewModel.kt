package com.aurum.musictv.ui.library

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.aurum.musictv.data.model.Song
import com.aurum.musictv.sync.SyncRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class LibraryTab { LIKED_SONGS, RECENTLY_PLAYED }

data class LibraryUiState(
    val tab: LibraryTab = LibraryTab.LIKED_SONGS,
    val likedSongs: List<Song> = emptyList(),
    val recentlyPlayed: List<Song> = emptyList(),
    val isLoading: Boolean = true,
)

/** Backs the dedicated Library screen — reuses the exact same Supabase
 *  reads ([SyncRepository.fetchLikedSongs] / [fetchRecentlyPlayed]) the
 *  old Home-row "Liked Songs"/"Recently Played" sections already used, so
 *  this is purely a new place to view existing data, not a new data
 *  source. */
class LibraryViewModel : ViewModel() {

    private val _uiState = MutableStateFlow(LibraryUiState())
    val uiState: StateFlow<LibraryUiState> = _uiState.asStateFlow()

    init {
        load()
    }

    fun selectTab(tab: LibraryTab) {
        _uiState.value = _uiState.value.copy(tab = tab)
    }

    fun refresh() = load()

    private fun load() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)
            val liked = runCatching { SyncRepository.fetchLikedSongs(limit = 100) }.getOrDefault(emptyList())
            val recent = runCatching { SyncRepository.fetchRecentlyPlayed(limit = 50) }.getOrDefault(emptyList())
            _uiState.value = _uiState.value.copy(
                likedSongs = liked,
                recentlyPlayed = recent,
                isLoading = false,
            )
        }
    }
}
