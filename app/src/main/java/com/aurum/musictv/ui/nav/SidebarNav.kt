package com.aurum.musictv.ui.nav

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.aurum.musictv.ui.theme.AurumColors

enum class NavDestination(val label: String, val glyph: String) {
    HOME("Home", "\u2302"),
    SEARCH("Search", "\uD83D\uDD0D"),
    LIBRARY("Library", "\uD83D\uDCDA"),
}

/**
 * Persistent left rail, Spotify-TV style — always visible next to Home/
 * Search/Library content instead of those being full-screen swaps reached
 * only via a top-bar icon. Narrow icon-only rail (not a full labeled
 * sidebar): TV screens are landscape and wide, but D-pad users still
 * benefit from a tight, low-travel-distance rail rather than a wide panel
 * eating into content width.
 *
 * NOT shown on the Player or Settings screens (see MainActivity) —
 * matches Spotify TV, where full-screen "now playing" and settings both
 * intentionally drop the rail to maximize their own content.
 */
@Composable
fun SidebarNav(
    current: NavDestination,
    onNavigate: (NavDestination) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxHeight()
            .width(88.dp)
            .background(AurumColors.AmoledBgCard)
            .padding(vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(28.dp),
    ) {
        Text(
            text = "A",
            color = AurumColors.Gold,
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        NavDestination.entries.forEach { destination ->
            SidebarIcon(
                destination = destination,
                selected = destination == current,
                onClick = { onNavigate(destination) },
            )
        }
    }
}

@Composable
private fun SidebarIcon(destination: NavDestination, selected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = ClickableSurfaceDefaults.shape(shape = RoundedCornerShape(12.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected) AurumColors.AmoledBgElevated else androidx.compose.ui.graphics.Color.Transparent,
            focusedContainerColor = AurumColors.AmoledBgElevated,
        ),
        border = ClickableSurfaceDefaults.border(
            focusedBorder = Border(
                border = androidx.compose.foundation.BorderStroke(2.dp, AurumColors.Gold),
                shape = RoundedCornerShape(12.dp),
            ),
        ),
        modifier = Modifier.width(64.dp),
    ) {
        Column(
            modifier = Modifier.padding(vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = destination.glyph,
                fontSize = 20.sp,
                color = if (selected) AurumColors.Gold else AurumColors.TextSecondary,
            )
            Text(
                text = destination.label,
                fontSize = 10.sp,
                color = if (selected) AurumColors.Gold else AurumColors.TextMuted,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            )
        }
    }
}
