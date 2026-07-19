package com.aurum.musictv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.weight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.aurum.musictv.data.model.Song
import com.aurum.musictv.data.model.toSong
import com.aurum.musictv.player.PlayerManager
import com.aurum.musictv.sync.AuthRepository
import com.aurum.musictv.sync.SyncRepository
import com.aurum.musictv.ui.auth.AuthScreen
import com.aurum.musictv.ui.home.HomeScreen
import com.aurum.musictv.ui.home.HomeViewModel
import com.aurum.musictv.ui.library.LibraryScreen
import com.aurum.musictv.ui.nav.NavDestination
import com.aurum.musictv.ui.nav.SidebarNav
import com.aurum.musictv.ui.player.PlayerScreen
import com.aurum.musictv.ui.search.SearchScreen
import com.aurum.musictv.ui.settings.SettingsScreen
import com.aurum.musictv.ui.theme.AurumColors
import com.aurum.musictv.ui.theme.AurumTvTheme
import kotlinx.coroutines.launch

/**
 * Single-Activity app, one PlayerManager instance for the whole lifecycle
 * (created here, not per-screen — see PlayerManager kdoc). Screen state is
 * a simple sealed enum instead of Navigation-Compose: the screen count is
 * still small enough that pulling in the whole Nav library would be dead
 * weight for this app's actual complexity.
 */
class MainActivity : ComponentActivity() {

    private lateinit var playerManager: PlayerManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        playerManager = PlayerManager(applicationContext)

        setContent {
            AurumTvTheme {
                AurumApp(playerManager = playerManager)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        playerManager.release()
    }
}

private sealed class Screen {
    data object Auth : Screen()
    data object Home : Screen()
    data object Search : Screen()
    data object Library : Screen()
    data object Player : Screen()
    data object Settings : Screen()
}

/** Which sidebar icon should read as "selected" for a given screen — Auth/
 *  Player/Settings aren't sidebar destinations themselves, so they fall
 *  back to whichever main tab the user came from conceptually (Home). */
private fun Screen.toNavDestinationOrNull(): NavDestination? = when (this) {
    Screen.Home -> NavDestination.HOME
    Screen.Search -> NavDestination.SEARCH
    Screen.Library -> NavDestination.LIBRARY
    else -> null
}

@Composable
private fun AurumApp(playerManager: PlayerManager) {
    // Login is optional — app always starts at Home so playback works
    // without signing in. Auth is only ever reached via the profile icon
    // in the top bar, same as Spotify TV: browsing/playback never
    // requires an account.
    var screen by remember { mutableStateOf<Screen>(Screen.Home) }
    val homeViewModel: HomeViewModel = viewModel()

    // Home's two background polls (remote-playback banner, premium
    // flag — see HomeViewModel/SyncRepository) only matter while Home is
    // actually the screen on screen. HomeViewModel is retained for the
    // whole Activity lifetime regardless of which screen is showing, so
    // without this signal those polls would keep firing network calls
    // every 8s/30s even while sitting on Player/Search/Library/Settings.
    // This is a plain LaunchedEffect keyed on `screen`, not a new
    // observer/listener system — zero added overhead of its own.
    LaunchedEffect(screen) {
        homeViewModel.setHomeVisible(screen is Screen.Home)
    }

    // The persistent left rail (Home/Search/Library) is Spotify-TV's
    // structure: a permanent nav rail sitting beside content, not a
    // full-screen swap reached only through a top-bar icon. It's hidden
    // for Player and Settings (see showSidebar below) — same as Spotify
    // TV, where "now playing" and settings both go full-bleed and
    // intentionally drop the rail to maximize their own content.
    val showSidebar = screen is Screen.Home || screen is Screen.Search || screen is Screen.Library

    // There was no BackHandler anywhere in the app — the remote's Back
    // button did nothing on Player/Search/Library/Settings/Auth, so it
    // either fell through to the OS (closing the app straight from
    // "now playing", which is jarring) or was silently swallowed
    // depending on the launcher. Every non-Home screen now returns to
    // Home; from Home itself Back falls through to the system default
    // (leaves the app), matching Spotify TV's remote behavior.
    BackHandler(enabled = screen != Screen.Home) {
        screen = Screen.Home
    }

    Row(modifier = Modifier.fillMaxSize().background(AurumColors.AmoledBg)) {
        if (showSidebar) {
            SidebarNav(
                current = screen.toNavDestinationOrNull() ?: NavDestination.HOME,
                onNavigate = { destination ->
                    screen = when (destination) {
                        NavDestination.HOME -> Screen.Home
                        NavDestination.SEARCH -> Screen.Search
                        NavDestination.LIBRARY -> Screen.Library
                    }
                },
            )
        }

        Box(modifier = Modifier.weight(1f)) {
            when (screen) {
                is Screen.Auth -> AuthScreen(
                    onSignedIn = {
                        homeViewModel.refreshAuthState()
                        screen = Screen.Home
                    },
                    onDismiss = {
                        homeViewModel.refreshAuthState()
                        screen = Screen.Home
                    },
                )

                is Screen.Home -> HomeScreen(
                    viewModel = homeViewModel,
                    onSongClick = { song, queue ->
                        val startIndex = queue.indexOf(song).coerceAtLeast(0)
                        playerManager.playQueue(queue, startIndex)
                        screen = Screen.Player
                    },
                    onResumeClick = { song, positionMs ->
                        // Prefer the full synced queue (pushQueue/fetchQueue)
                        // so resuming on TV continues the same playlist
                        // phone was in, not just the single song — falls
                        // back to a one-song queue if the queue table has
                        // nothing (e.g. phone was playing a lone track, or
                        // the fetch fails).
                        homeViewModel.viewModelScope.launch {
                            val queueRow = runCatching { SyncRepository.fetchQueue() }.getOrNull()
                            val queueSongs = queueRow?.items?.map { it.toSong() }
                            if (!queueSongs.isNullOrEmpty() && queueSongs.any { it.id == song.id }) {
                                val startIndex = queueSongs.indexOfFirst { it.id == song.id }.coerceAtLeast(0)
                                playerManager.playQueue(queueSongs, startIndex)
                                kotlinx.coroutines.delay(500) // let prepare() land first, same as resumeFrom()
                                playerManager.seekTo(positionMs)
                            } else {
                                playerManager.resumeFrom(song, positionMs)
                            }
                        }
                        screen = Screen.Player
                    },
                    onSearchClick = { screen = Screen.Search },
                    onProfileClick = { screen = Screen.Auth },
                    onSettingsClick = { screen = Screen.Settings },
                )

                is Screen.Search -> SearchScreen(
                    onSongClick = { song, results ->
                        val startIndex = results.indexOf(song).coerceAtLeast(0)
                        playerManager.playQueue(results, startIndex)
                        screen = Screen.Player
                    },
                )

                is Screen.Library -> LibraryScreen(
                    onSongClick = { song, results ->
                        val startIndex = results.indexOf(song).coerceAtLeast(0)
                        playerManager.playQueue(results, startIndex)
                        screen = Screen.Player
                    },
                )

                is Screen.Player -> PlayerScreen(playerManager = playerManager)

                is Screen.Settings -> SettingsScreen(onBack = { screen = Screen.Home })
            }
        }
    }
}
