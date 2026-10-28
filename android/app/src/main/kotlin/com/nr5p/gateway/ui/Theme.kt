package com.nr5p.gateway.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** The teal of the app icon. */
val Teal = Color(0xFF00897B)
val TealLight = Color(0xFF6BD4B6)

private val light = lightColorScheme(
    primary = Teal,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFB2EADB),
    onPrimaryContainer = Color(0xFF00201A),
    secondary = Color(0xFF4A635C),
    secondaryContainer = Color(0xFFB2EADB),
    // Neutral greys like the iOS grouped forms, instead of Material's purple-tinted defaults.
    background = Color(0xFFF2F2F7),
    surface = Color(0xFFF2F2F7),
    surfaceVariant = Color(0xFFE5E5EA),
    surfaceContainer = Color(0xFFF2F2F7),
    surfaceContainerLow = Color(0xFFF2F2F7),
    surfaceContainerHigh = Color(0xFFFFFFFF),
    surfaceContainerHighest = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF5F6368),
)

private val dark = darkColorScheme(
    primary = TealLight,
    onPrimary = Color(0xFF00382E),
    primaryContainer = Color(0xFF00513F),
    onPrimaryContainer = Color(0xFFB2EADB),
    secondary = Color(0xFFB1CCC3),
    secondaryContainer = Color(0xFF00513F),
    background = Color(0xFF000000),
    surface = Color(0xFF000000),
    surfaceVariant = Color(0xFF2C2C2E),
    surfaceContainer = Color(0xFF1C1C1E),
    surfaceContainerLow = Color(0xFF000000),
    surfaceContainerHigh = Color(0xFF1C1C1E),
    surfaceContainerHighest = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFF9A9AA0),
)

@Composable
fun GatewayTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) dark else light, content = content)
}
