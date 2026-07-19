package com.aurum.musictv.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.aurum.musictv.settings.AppTheme
import com.aurum.musictv.settings.AudioQuality
import com.aurum.musictv.ui.theme.AurumColors

/**
 * Full Settings screen — Network + Playback prefs (Theme, Audio Quality,
 * Autoplay, Crossfade, Normalize Volume) + Storage (Clear Cache) + Account
 * (About, Privacy, Logout, Device Info). Every row is a focusable
 * tv-material Surface so it's fully D-pad navigable, same pattern as
 * SongCard/TopBar elsewhere in the app — no new focus-handling approach
 * introduced.
 */
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel = viewModel(),
) {
    val state by viewModel.uiState.collectAsState()

    LaunchedEffect(state.cacheCleared) {
        if (state.cacheCleared) {
            kotlinx.coroutines.delay(2000)
            viewModel.dismissCacheClearedNotice()
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().background(AurumColors.AmoledBg),
        contentPadding = PaddingValues(horizontal = 48.dp, vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(28.dp),
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Settings", color = AurumColors.TextPrimary, fontSize = 30.sp, fontWeight = FontWeight.Bold)
                BackChip(onClick = onBack)
            }
        }

        item { SectionHeader("Playback") }
        item {
            SettingsGroup {
                ThemeRow(current = state.settings.theme, onSelect = viewModel::setTheme)
                AudioQualityRow(current = state.settings.audioQuality, onSelect = viewModel::setAudioQuality)
                ToggleRow(
                    label = "Autoplay",
                    description = "Automatically play the next song in queue",
                    checked = state.settings.autoplay,
                    onToggle = viewModel::setAutoplay,
                )
                CrossfadeRow(
                    seconds = state.settings.crossfadeSeconds,
                    onChange = viewModel::setCrossfadeSeconds,
                )
                ToggleRow(
                    label = "Normalize Volume",
                    description = "Keep loudness consistent across songs and sources",
                    checked = state.settings.normalizeVolume,
                    onToggle = viewModel::setNormalizeVolume,
                )
            }
        }

        item { SectionHeader("Storage") }
        item {
            SettingsGroup {
                ActionRow(
                    label = "Clear Cache",
                    valueLabel = if (state.cacheCleared) "Cleared!" else state.cacheSizeLabel,
                    onClick = viewModel::clearCache,
                )
            }
        }

        item { SectionHeader("Account") }
        item {
            SettingsGroup {
                InfoRow(label = "About", valueLabel = "Aurum TV v${state.appVersion}")
                InfoRow(label = "Privacy", valueLabel = "How your data is used")
                if (state.isSignedIn) {
                    ActionRow(
                        label = "Logout",
                        valueLabel = state.accountLabel ?: "Signed in",
                        destructive = true,
                        onClick = viewModel::logout,
                    )
                } else {
                    InfoRow(label = "Account", valueLabel = "Not signed in")
                }
            }
        }

        item { SectionHeader("Device Info") }
        item {
            SettingsGroup {
                InfoRow(label = "Device", valueLabel = state.deviceModel)
                InfoRow(label = "Android Version", valueLabel = state.androidVersion)
                InfoRow(label = "App Version", valueLabel = state.appVersion)
            }
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        color = AurumColors.Gold,
        fontSize = 13.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(bottom = 4.dp),
    )
}

@Composable
private fun SettingsGroup(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(AurumColors.AmoledBgCard),
    ) {
        content()
    }
}

@Composable
private fun RowContainer(content: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 18.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

@Composable
private fun InfoRow(label: String, valueLabel: String) {
    RowContainer {
        Text(label, color = AurumColors.TextPrimary, fontSize = 16.sp)
        Text(valueLabel, color = AurumColors.TextSecondary, fontSize = 14.sp)
    }
}

@Composable
private fun ActionRow(label: String, valueLabel: String, destructive: Boolean = false, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = RoundedCornerShape(0.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = androidx.compose.ui.graphics.Color.Transparent,
            focusedContainerColor = AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(
                    2.dp,
                    if (destructive) androidx.compose.ui.graphics.Color(0xFFE05656) else AurumColors.Gold,
                ),
                shape = RoundedCornerShape(0.dp),
            ),
        ),
    ) {
        RowContainer {
            Text(
                label,
                color = if (destructive) androidx.compose.ui.graphics.Color(0xFFE05656) else AurumColors.TextPrimary,
                fontSize = 16.sp,
            )
            Text(valueLabel, color = AurumColors.TextSecondary, fontSize = 14.sp)
        }
    }
}

@Composable
private fun ToggleRow(label: String, description: String, checked: Boolean, onToggle: (Boolean) -> Unit) {
    Surface(
        onClick = { onToggle(!checked) },
        modifier = Modifier.fillMaxWidth(),
        shape = ClickableSurfaceDefaults.shape(shape = RoundedCornerShape(0.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = androidx.compose.ui.graphics.Color.Transparent,
            focusedContainerColor = AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                shape = RoundedCornerShape(0.dp),
            ),
        ),
    ) {
        RowContainer {
            Column {
                Text(label, color = AurumColors.TextPrimary, fontSize = 16.sp)
                Text(description, color = AurumColors.TextSecondary, fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
            }
            SwitchDot(checked = checked)
        }
    }
}

@Composable
private fun SwitchDot(checked: Boolean) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (checked) AurumColors.Gold else AurumColors.AmoledDivider)
            .padding(3.dp),
    ) {
        Column(modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)) {
            Text(if (checked) "ON" else "OFF", color = AurumColors.AmoledBg, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun ThemeRow(current: AppTheme, onSelect: (AppTheme) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 24.dp, vertical = 18.dp)) {
        Text("Theme", color = AurumColors.TextPrimary, fontSize = 16.sp)
        Row(
            modifier = Modifier.padding(top = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AppTheme.entries.forEach { theme ->
                ChoiceChip(
                    label = theme.name.replace('_', ' ').lowercase()
                        .replaceFirstChar { it.uppercase() },
                    selected = theme == current,
                    onClick = { onSelect(theme) },
                )
            }
        }
    }
}

@Composable
private fun AudioQualityRow(current: AudioQuality, onSelect: (AudioQuality) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 24.dp, vertical = 18.dp)) {
        Text("Audio Quality", color = AurumColors.TextPrimary, fontSize = 16.sp)
        Row(
            modifier = Modifier.padding(top = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AudioQuality.entries.forEach { quality ->
                ChoiceChip(
                    label = when (quality) {
                        AudioQuality.LOW -> "Low"
                        AudioQuality.NORMAL -> "Normal"
                        AudioQuality.HIGH -> "High"
                        AudioQuality.LOSSLESS_IF_AVAILABLE -> "Lossless"
                    },
                    selected = quality == current,
                    onClick = { onSelect(quality) },
                )
            }
        }
    }
}

@Composable
private fun CrossfadeRow(seconds: Int, onChange: (Int) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 24.dp, vertical = 18.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("Crossfade", color = AurumColors.TextPrimary, fontSize = 16.sp)
            Text(if (seconds == 0) "Off" else "${seconds}s", color = AurumColors.TextSecondary, fontSize = 14.sp)
        }
        Row(
            modifier = Modifier.padding(top = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            listOf(0, 2, 4, 6, 8, 12).forEach { value ->
                ChoiceChip(
                    label = if (value == 0) "Off" else "${value}s",
                    selected = value == seconds,
                    onClick = { onChange(value) },
                )
            }
        }
    }
}

@Composable
private fun ChoiceChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(shape = RoundedCornerShape(20.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) AurumColors.Gold else AurumColors.AmoledBgSurface,
            focusedContainerColor = if (selected) AurumColors.GoldLight else AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                shape = RoundedCornerShape(20.dp),
            ),
        ),
    ) {
        Text(
            label,
            color = if (selected) AurumColors.AmoledBg else AurumColors.TextPrimary,
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun BackChip(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(shape = RoundedCornerShape(8.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = AurumColors.AmoledBgSurface,
            focusedContainerColor = AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                shape = RoundedCornerShape(8.dp),
            ),
        ),
    ) {
        Text(
            "Back",
            color = AurumColors.TextPrimary,
            fontSize = 14.sp,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
        )
    }
}
