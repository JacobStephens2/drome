package day.drome.app

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

object DromeColors {
    val Sand = Color(0xFFF3EAD8)
    val NightSand = Color(0xFF1C1917)
    val Ink = Color(0xFF1C1917)
    val NightInk = Color(0xFFF5F5F4)
    val Clay = Color(0xFFC2410C)
    val Camel = Color(0xFFB45309)
    val Oasis = Color(0xFF0E7490)
    val NightOasis = Color(0xFF22D3EE)
    val Done = Color(0xFF15803D)
    val Miss = Color(0xFFB91C1C)
    val Card = Color(0xFFFFFBEB)
    val NightCard = Color(0xFF292524)
}

private val LightScheme = lightColorScheme(
    primary = DromeColors.Clay,
    onPrimary = Color.White,
    secondary = DromeColors.Camel,
    tertiary = DromeColors.Oasis,
    background = DromeColors.Sand,
    onBackground = DromeColors.Ink,
    surface = DromeColors.Card,
    onSurface = DromeColors.Ink,
    error = DromeColors.Miss,
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFFFB923C),
    secondary = Color(0xFFF59E0B),
    tertiary = DromeColors.NightOasis,
    background = DromeColors.NightSand,
    onBackground = DromeColors.NightInk,
    surface = DromeColors.NightCard,
    onSurface = DromeColors.NightInk,
    error = Color(0xFFFCA5A5),
)

@Composable
fun DromeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val view = LocalView.current
    if (!view.isInEditMode) {
        val window = (view.context as? Activity)?.window
        if (window != null) {
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !dark
            if (Build.VERSION.SDK_INT >= 26) {
                WindowCompat.getInsetsController(window, view).isAppearanceLightNavigationBars = !dark
            }
        }
    }
    MaterialTheme(colorScheme = if (dark) DarkScheme else LightScheme, content = content)
}
