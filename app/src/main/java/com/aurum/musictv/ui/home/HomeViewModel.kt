package com.aurum.musictv.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.aurum.musictv.data.model.PlaybackStateRow
import com.aurum.musictv.data.model.Song
import com.aurum.musictv.data.model.toSong
import com.aurum.musictv.data.remote.AurumApi
import com.aurum.musictv.sync.AuthRepository
import com.aurum.musictv.sync.SyncRepository
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class HomeUiState(
    val isLoading: Boolean = true,
    val greetingName: String? = null,
    /** Google avatar URL when signed in, null otherwise -> ProfileAvatar
     *  falls back to a default icon. Sign-in is optional; this is purely
     *  cosmetic and never gates anything. */
    val avatarUrl: String? = null,
    val continueListening: Song? = null,
    /** Songs shown in the auto-rotating hero carousel at the top of Home
     *  — one random pick per section (so it spans categories, not just
     *  one row) rather than always the same fixed song. Recomputed each
     *  [HomeViewModel.loadHome] call, not on every recomposition. */
    val heroSongs: List<Song> = emptyList(),
    /** All browse rows (Trending, New Releases, Made For You, ...) in the
     *  order the API returns them — HomeScreen renders each as its own
     *  row, so adding a section server-side needs no client change. */
    val sections: List<Pair<String, List<Song>>> = emptyList(),
    val recentlyPlayed: List<Song> = emptyList(),
    val likedSongs: List<Song> = emptyList(),
    val isPremium: Boolean = false,
    /** Non-null while the OTHER device (mobile) is actively playing
     *  something TV isn't currently playing — drives the
     *  "Playing on phone" resume banner. */
    val remoteNowPlaying: PlaybackStateRow? = null,
)

class HomeViewModel : ViewModel() {

    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    // HomeViewModel is retained for the whole Activity lifetime (that's
    // how viewModel() works), but the two polling loops below only make
    // sense while Home is the screen actually on screen — the "Playing
    // on phone" banner and premium-flag refresh are both things the user
    // can only see on Home. Without this flag they kept firing a network
    // request every 8s/30s even while the user was sitting on Player,
    // Search, Library, or Settings — pure wasted radio/CPU wakeups on a
    // 1GB box for a screen that isn't even visible. MainActivity flips
    // this via setHomeVisible() on every screen change.
    private var isHomeVisible = true

    fun setHomeVisible(visible: Boolean) {
        isHomeVisible = visible
    }

    init {
        loadHome()
        observeRemotePlayback()
        observePremium()
        autoRefreshPeriodically()
    }

    /** TV has no swipe-to-refresh gesture (D-pad only), so instead of
     *  relying on the user to manually trigger refresh(), Home reloads
     *  itself every 10 minutes while it's the active screen — the
     *  randomized query pools in AurumApi.homeSections() mean each reload
     *  actually surfaces different songs, not just a repeat network call.
     *  Skipped entirely while Home isn't visible — no point refreshing
     *  browse rows the user isn't looking at; it'll refresh next time
     *  they land back on Home instead (see setHomeVisible). */
    private fun autoRefreshPeriodically() {
        viewModelScope.launch {
            while (true) {
                delay(10 * 60 * 1000L)
                if (isHomeVisible) loadHome()
            }
        }
    }

    private fun loadHome() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(
                isLoading = true,
                greetingName = AuthRepository.displayName,
                avatarUrl = AuthRepository.avatarUrl,
            )

            // Uses the same homeSections() the phone app's home screen is
            // built from — same Worker call, same content, not a
            // reinvented query. Rendered generically by HomeScreen so
            // adding a row server-side needs no client change.
            val sections = runCatching { AurumApi.homeSections() }.getOrDefault(emptyList())

            // One random song per section -> the hero carousel spans
            // different categories each time Home loads, instead of
            // always showing the same first song from the first row.
            val heroSongs = sections
                .mapNotNull { (_, songs) -> songs.randomOrNull() }
                .shuffled()
                .take(6)

            val playbackState = SyncRepository.fetchPlaybackState()
            val continueListening = playbackState?.songData?.toSong()

            val recent = runCatching { SyncRepository.fetchRecentlyPlayed() }.getOrDefault(emptyList())
            val liked = runCatching { SyncRepository.fetchLikedSongs() }.getOrDefault(emptyList())

            val isPremium = SyncRepository.fetchIsPremium()

            _uiState.value = _uiState.value.copy(
                isLoading = false,
                sections = sections,
                heroSongs = heroSongs,
                continueListening = continueListening,
                recentlyPlayed = recent,
                likedSongs = liked,
                isPremium = isPremium,
            )
        }
    }

    /** Listens for mobile pushing a new playback_state row while TV is
     *  sitting on Home — shows a lightweight "Resume on TV" banner instead
     *  of silently doing nothing (which is what would happen with zero
     *  realtime wiring). */
    private fun observeRemotePlayback() {
        viewModelScope.launch {
            SyncRepository.observePlaybackState(viewModelScope, isActive = { isHomeVisible }).collect { row ->
                if (row.device != "tv") {
                    _uiState.value = _uiState.value.copy(remoteNowPlaying = row)
                }
            }
        }
    }

    private fun observePremium() {
        viewModelScope.launch {
            SyncRepository.observeIsPremium(viewModelScope, isActive = { isHomeVisible }).collect { premium ->
                _uiState.value = _uiState.value.copy(isPremium = premium)
            }
        }
    }

    fun dismissRemoteNowPlaying() {
        _uiState.value = _uiState.value.copy(remoteNowPlaying = null)
    }

    fun refresh() = loadHome()

    /** Called when returning from the Auth screen (sign-in, sign-out, or
     *  just dismissed) so the profile icon / greeting reflect the latest
     *  state without a full home reload. */
    fun refreshAuthState() {
        _uiState.value = _uiState.value.copy(
            greetingName = AuthRepository.displayName,
            avatarUrl = AuthRepository.avatarUrl,
        )
    }
}
