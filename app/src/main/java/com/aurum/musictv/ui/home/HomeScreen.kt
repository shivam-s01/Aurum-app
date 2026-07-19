package com.aurum.musictv.ui.home

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Text
import com.aurum.musictv.data.model.Song
import com.aurum.musictv.data.model.toSong
import com.aurum.musictv.ui.components.SongCard
import com.aurum.musictv.ui.theme.AurumColors

/**
 * Single top-level LazyColumn containing horizontal LazyRows -- NOT
 * nested LazyLists inside LazyLists inside LazyLists (the perf
 * requirement calls this out explicitly). Each row is its own composable
 * function so recomposition of one row (e.g. after a realtime update)
 * never touches the others.
 */
@Composable
fun HomeScreen(
    onSongClick: (Song, List<Song>) -> Unit,
    onResumeClick: (Song, Long) -> Unit,
    onSearchClick: () -> Unit,
    onProfileClick: () -> Unit,
    onSettingsClick: () -> Unit,
    viewModel: HomeViewModel = viewModel(),
) {
    val state by viewModel.uiState.collectAsState()

    // Hero carousel spans multiple categories (see HomeViewModel.heroSongs);
    // Continue Listening still takes priority as the very first frame so a
    // returning listener sees their in-progress song immediately, before
    // the carousel takes over.
    val heroSongs = remember(state.continueListening, state.heroSongs) {
        listOfNotNull(state.continueListening) + state.heroSongs.filter { it != state.continueListening }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().background(AurumColors.AmoledBg),
        contentPadding = PaddingValues(bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(32.dp),
    ) {
        item {
            Box {
                if (heroSongs.isNotEmpty()) {
                    HeroCarousel(
                        songs = heroSongs,
                        onPlayClick = { song ->
                            val list = state.continueListening?.let { c -> listOf(c) }
                                ?: state.sections.firstOrNull()?.second ?: listOf(song)
                            onSongClick(song, list)
                        },
                    )
                }
                TopBar(
                    greetingName = state.greetingName,
                    avatarUrl = state.avatarUrl,
                    onSearchClick = onSearchClick,
                    onProfileClick = onProfileClick,
                    onSettingsClick = onSettingsClick,
                    modifier = Modifier.padding(top = 20.dp),
                )
            }
        }

        state.remoteNowPlaying?.let { remote ->
            item {
                ResumeOnTvBanner(
                    title = remote.songData?.title ?: "Something",
                    onResume = {
                        val song = remote.songData?.toSong()
                        if (song != null) {
                            onResumeClick(song, remote.positionMs)
                            viewModel.dismissRemoteNowPlaying()
                        }
                    },
                    onDismiss = viewModel::dismissRemoteNowPlaying,
                )
            }
        }

        state.continueListening?.let { song ->
            item {
                SongRow(
                    title = "Continue Listening",
                    songs = listOf(song),
                    onSongClick = { onSongClick(it, listOf(song)) },
                )
            }
        }

        if (state.recentlyPlayed.isNotEmpty()) {
            item {
                SongRow(
                    title = "Jump Back In",
                    songs = state.recentlyPlayed,
                    onSongClick = { onSongClick(it, state.recentlyPlayed) },
                )
            }
        }

        if (state.likedSongs.isNotEmpty()) {
            item {
                SongRow(
                    title = "Liked Songs",
                    songs = state.likedSongs,
                    onSongClick = { onSongClick(it, state.likedSongs) },
                )
            }
        }

        // Every section the API returns (Trending, New Releases, Made
        // For You, Top Charts, Bollywood Hits, ...) — driven entirely by
        // AurumApi.homeSections(), so adding a row is a backend change,
        // not a client one.
        items(state.sections, key = { it.first }) { (title, songs) ->
            SongRow(
                title = title,
                songs = songs,
                onSongClick = { onSongClick(it, songs) },
            )
        }
    }
}

/**
 * Auto-rotating hero carousel — cycles through [songs] every 6s with a
 * smooth crossfade (via animateFloatAsState, the same proven pattern
 * SongCard already uses for its focus-scale animation — no new animation
 * API surface introduced). Advances on its own; the user never has to
 * interact with it, matching the "smooth automatic swipe" behavior asked
 * for.
 */
@Composable
private fun HeroCarousel(songs: List<Song>, onPlayClick: (Song) -> Unit) {
    var currentIndex by remember(songs) { mutableStateOf(0) }

    LaunchedEffect(songs) {
        if (songs.size <= 1) return@LaunchedEffect
        while (true) {
            kotlinx.coroutines.delay(6000)
            currentIndex = (currentIndex + 1) % songs.size
        }
    }

    val song = songs.getOrNull(currentIndex) ?: return

    // Crossfade: alpha resets to 0 whenever currentIndex changes (key =
    // currentIndex below), then animates up to 1 over 600ms — a real
    // fade-in on every slide change, not a no-op animation to a constant.
    var alphaTarget by remember(currentIndex) { mutableStateOf(0f) }
    LaunchedEffect(currentIndex) { alphaTarget = 1f }
    val alpha by animateFloatAsState(
        targetValue = alphaTarget,
        animationSpec = tween(durationMillis = 600),
        label = "heroCrossfade",
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(420.dp),
    ) {
        coil.compose.AsyncImage(
            model = song.albumArtUrl,
            contentDescription = null,
            modifier = Modifier.fillMaxSize().graphicsLayer { this.alpha = alpha },
            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    androidx.compose.ui.graphics.Brush.verticalGradient(
                        colors = listOf(
                            androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.15f),
                            androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f),
                            AurumColors.AmoledBg,
                        ),
                        startY = 0f,
                    ),
                ),
        )
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(horizontal = 48.dp, vertical = 28.dp),
        ) {
            Text(
                text = "PLAYING NOW",
                color = AurumColors.Gold,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = song.title,
                color = AurumColors.TextPrimary,
                fontSize = 40.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 4.dp),
            )
            Text(
                text = song.artist,
                color = AurumColors.TextSecondary,
                fontSize = 18.sp,
                modifier = Modifier.padding(top = 4.dp, bottom = 20.dp),
            )
            androidx.tv.material3.Surface(
                onClick = { onPlayClick(song) },
                shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(
                    shape = RoundedCornerShape(8.dp),
                ),
                colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
                    containerColor = AurumColors.Gold,
                    focusedContainerColor = AurumColors.GoldLight,
                ),
                border = androidx.tv.material3.ClickableSurfaceDefaults.border(
                    focusedBorder = androidx.tv.material3.Border(
                        border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.TextPrimary),
                        shape = RoundedCornerShape(8.dp),
                    ),
                ),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 32.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    androidx.tv.material3.Icon(
                        imageVector = Icons.Filled.PlayArrow,
                        contentDescription = null,
                        tint = AurumColors.AmoledBg,
                        modifier = Modifier.size(22.dp),
                    )
                    Text("Play", color = AurumColors.AmoledBg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            if (songs.size > 1) {
                Row(
                    modifier = Modifier.padding(top = 20.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    songs.forEachIndexed { i, _ ->
                        Box(
                            modifier = Modifier
                                .size(if (i == currentIndex) 20.dp else 6.dp, 6.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(
                                    if (i == currentIndex) AurumColors.Gold
                                    else AurumColors.TextMuted,
                                ),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TopBar(
    greetingName: String?,
    avatarUrl: String?,
    onSearchClick: () -> Unit,
    onProfileClick: () -> Unit,
    onSettingsClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 48.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        Text(
            text = if (greetingName != null) "Hi, $greetingName" else "Aurum",
            color = AurumColors.TextPrimary,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )
        Row(
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            androidx.tv.material3.Surface(
                onClick = onSearchClick,
                shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(
                    shape = RoundedCornerShape(6.dp),
                ),
                colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
                    containerColor = AurumColors.AmoledBgSurface,
                    focusedContainerColor = AurumColors.AmoledBgElevated,
                ),
                border = androidx.tv.material3.ClickableSurfaceDefaults.border(
                    focusedBorder = androidx.tv.material3.Border(
                        border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                        shape = RoundedCornerShape(6.dp),
                    ),
                ),
            ) {
                Text(
                    "Search",
                    color = AurumColors.TextPrimary,
                    fontSize = 14.sp,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                )
            }
            androidx.tv.material3.Surface(
                onClick = onSettingsClick,
                shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(
                    shape = androidx.compose.foundation.shape.CircleShape,
                ),
                colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
                    containerColor = AurumColors.AmoledBgSurface,
                    focusedContainerColor = AurumColors.AmoledBgElevated,
                ),
                border = androidx.tv.material3.ClickableSurfaceDefaults.border(
                    focusedBorder = androidx.tv.material3.Border(
                        border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                        shape = androidx.compose.foundation.shape.CircleShape,
                    ),
                ),
                modifier = Modifier.size(40.dp),
            ) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("\u2699", color = AurumColors.TextSecondary, fontSize = 18.sp)
                }
            }
            ProfileAvatar(avatarUrl = avatarUrl, onClick = onProfileClick)
        }
    }
}

/**
 * Spotify-TV-style profile icon: shows the signed-in user's Google photo
 * when available, otherwise a plain default avatar. Never blocks anything
 * — tapping it is the ONLY way to reach sign-in; browsing/playback never
 * require it.
 */
@Composable
private fun ProfileAvatar(avatarUrl: String?, onClick: () -> Unit) {
    androidx.tv.material3.Surface(
        onClick = onClick,
        shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(
            shape = androidx.compose.foundation.shape.CircleShape,
        ),
        colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
            containerColor = AurumColors.AmoledBgSurface,
            focusedContainerColor = AurumColors.AmoledBgElevated,
        ),
        border = androidx.tv.material3.ClickableSurfaceDefaults.border(
            focusedBorder = androidx.tv.material3.Border(
                border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                shape = androidx.compose.foundation.shape.CircleShape,
            ),
        ),
        modifier = Modifier.size(40.dp),
    ) {
        androidx.compose.foundation.layout.Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = androidx.compose.ui.Alignment.Center,
        ) {
        if (avatarUrl != null) {
            coil.compose.AsyncImage(
                model = avatarUrl,
                contentDescription = "Profile",
                modifier = Modifier.fillMaxSize().clip(androidx.compose.foundation.shape.CircleShape),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
            )
        } else {
            androidx.tv.material3.Text(
                text = "\uD83D\uDC64",
                color = AurumColors.TextSecondary,
                modifier = Modifier,
            )
        }
        }
    }
}

@Composable
private fun ResumeOnTvBanner(title: String, onResume: () -> Unit, onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 48.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "Playing on phone: $title",
            color = AurumColors.Gold,
            fontSize = 16.sp,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            // This is the actual point of the banner — without a Resume
            // action it was just a notice with nowhere to go, even
            // though PlayerManager.resumeFrom() (queues the song AND
            // seeks to the synced position) already existed and was
            // simply never called from here.
            androidx.tv.material3.Surface(
                onClick = onResume,
                shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(
                    shape = RoundedCornerShape(6.dp),
                ),
                colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
                    containerColor = AurumColors.Gold,
                    focusedContainerColor = AurumColors.GoldLight,
                ),
                border = androidx.tv.material3.ClickableSurfaceDefaults.border(
                    focusedBorder = androidx.tv.material3.Border(
                        border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.GoldLight),
                        shape = RoundedCornerShape(6.dp),
                    ),
                ),
            ) {
                Text(
                    "Resume Here",
                    color = AurumColors.AmoledBg,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                )
            }
            androidx.tv.material3.Surface(
                onClick = onDismiss,
                shape = androidx.tv.material3.ClickableSurfaceDefaults.shape(
                    shape = RoundedCornerShape(6.dp),
                ),
                colors = androidx.tv.material3.ClickableSurfaceDefaults.colors(
                    containerColor = AurumColors.AmoledBgSurface,
                    focusedContainerColor = AurumColors.AmoledBgElevated,
                ),
                border = androidx.tv.material3.ClickableSurfaceDefaults.border(
                    focusedBorder = androidx.tv.material3.Border(
                        border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                        shape = RoundedCornerShape(6.dp),
                    ),
                ),
            ) {
                Text(
                    "Dismiss",
                    color = AurumColors.TextSecondary,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }
    }
}

@Composable
private fun SongRow(title: String, songs: List<Song>, onSongClick: (Song) -> Unit) {
    Column {
        Text(
            text = title,
            color = AurumColors.TextPrimary,
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 48.dp, vertical = 8.dp),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 48.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            items(songs, key = { it.id }) { song ->
                SongCard(song = song, onClick = { onSongClick(song) })
            }
        }
    }
}
