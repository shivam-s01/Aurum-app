package com.aurum.musictv.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import coil.compose.AsyncImage
import com.aurum.musictv.player.PlayerManager
import com.aurum.musictv.ui.theme.AurumColors
import kotlinx.coroutines.delay

/**
 * Progress bar and controls are built from plain foundation Box/Row for
 * layout, but every actionable control is a tv-material Surface (not a
 * bare Modifier.clickable) — that's what gives D-pad users a visible
 * focus ring per control. A plain clickable Box has no focus indicator on
 * TV, which made these buttons effectively invisible to remote
 * navigation (you could press the wrong one and not know it).
 */
@Composable
fun PlayerScreen(playerManager: PlayerManager) {
    val state by playerManager.uiState.collectAsState()
    val song = state.currentSong ?: return

    Box(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxSize().padding(48.dp),
            horizontalArrangement = Arrangement.spacedBy(48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AsyncImage(
                model = song.albumArtUrl,
                contentDescription = song.title,
                modifier = Modifier.size(360.dp).clip(RoundedCornerShape(16.dp)),
                contentScale = ContentScale.Crop,
            )

            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Top,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = song.title,
                            color = AurumColors.TextPrimary,
                            fontSize = 32.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 2,
                        )
                        Text(
                            text = song.artist,
                            color = AurumColors.TextSecondary,
                            fontSize = 18.sp,
                            modifier = Modifier.padding(top = 4.dp, bottom = 24.dp),
                        )
                    }
                    // Heart / save-to-Library toggle — this is what "save
                    // to Library" from the Player screen means: writes to
                    // the exact same liked_songs row LibraryScreen's
                    // "Liked Songs" tab reads.
                    LikeButton(
                        liked = state.isCurrentSongLiked,
                        onClick = { playerManager.toggleLikeCurrentSong() },
                    )
                }

                val progress = if (state.durationMs > 0) {
                    (state.positionMs.toFloat() / state.durationMs.toFloat()).coerceIn(0f, 1f)
                } else 0f

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(AurumColors.AmoledDivider),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(progress)
                            .clip(RoundedCornerShape(2.dp))
                            .background(AurumColors.Gold),
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(formatMs(state.positionMs), color = AurumColors.TextSecondary, fontSize = 13.sp)
                    Text(formatMs(state.durationMs), color = AurumColors.TextSecondary, fontSize = 13.sp)
                }

                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 32.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TransportButton(
                        icon = Icons.Filled.SkipPrevious,
                        contentDescription = "Previous",
                        size = 28.dp,
                        tint = AurumColors.TextPrimary,
                        onClick = { playerManager.playPrevious() },
                    )
                    Box(modifier = Modifier.padding(horizontal = 24.dp)) {
                        TransportButton(
                            icon = if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = "Play/Pause",
                            size = 40.dp,
                            tint = AurumColors.AmoledBg,
                            background = AurumColors.Gold,
                            onClick = { playerManager.togglePlayPause() },
                        )
                    }
                    TransportButton(
                        icon = Icons.Filled.SkipNext,
                        contentDescription = "Next",
                        size = 28.dp,
                        tint = AurumColors.TextPrimary,
                        onClick = { playerManager.playNext() },
                    )
                }
            }
        }

        // Playback error toast — surfaces the click-failure/auto-skip
        // feedback from PlayerManager instead of leaving the user
        // guessing whether their remote press registered.
        state.playbackError?.let { error ->
            PlaybackErrorToast(message = error, onDismiss = { playerManager.dismissPlaybackError() })
        }
    }
}

@Composable
private fun PlaybackErrorToast(message: String, onDismiss: () -> Unit) {
    LaunchedEffect(message) {
        delay(3000)
        onDismiss()
    }
    Box(modifier = Modifier.fillMaxSize().padding(bottom = 32.dp), contentAlignment = Alignment.BottomCenter) {
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .background(AurumColors.AmoledBgElevated)
                .padding(horizontal = 20.dp, vertical = 12.dp),
        ) {
            Text(message, color = AurumColors.TextPrimary, fontSize = 14.sp)
        }
    }
}

@Composable
private fun LikeButton(liked: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(shape = CircleShape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = AurumColors.AmoledBgSurface,
            focusedContainerColor = AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                shape = CircleShape,
            ),
        ),
        modifier = Modifier.size(52.dp),
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                contentDescription = if (liked) "Remove from Liked Songs" else "Save to Liked Songs",
                tint = if (liked) AurumColors.Gold else AurumColors.TextSecondary,
                modifier = Modifier.size(24.dp),
            )
        }
    }
}

@Composable
private fun TransportButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    size: androidx.compose.ui.unit.Dp,
    tint: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit,
    background: androidx.compose.ui.graphics.Color? = null,
) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(shape = CircleShape),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = background ?: AurumColors.AmoledBgSurface,
            focusedContainerColor = background ?: AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(3.dp, AurumColors.GoldLight),
                shape = CircleShape,
            ),
        ),
        modifier = Modifier.size(if (background != null) size + 32.dp else size + 16.dp),
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = contentDescription,
                tint = tint,
                modifier = Modifier.size(size),
            )
        }
    }
}

private fun formatMs(ms: Long): String {
    val totalSec = ms / 1000
    val min = totalSec / 60
    val sec = totalSec % 60
    return "%d:%02d".format(min, sec)
}
