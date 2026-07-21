package day.drome.app.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Button
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.GlanceTheme
import day.drome.app.DromeCoreProvider
import day.drome.core.ContainerPreset
import day.drome.core.WaterUnits
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private val AmountKey = ActionParameters.Key<Long>("water_ml")

class DromeWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        // Cold-start-safe: the widget may be the first component in this process.
        val snapshot = runCatching {
            withContext(Dispatchers.IO) {
                val core = DromeCoreProvider.get(context)
                core.today() to core.containerPresets()
            }
        }.getOrNull()
        provideContent { GlanceTheme { WidgetContent(snapshot?.first?.day?.waterMl, snapshot?.first?.day?.waterGoalMl, snapshot?.second.orEmpty()) } }
    }
}

class DromeWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = DromeWidget()
}

@Composable
private fun WidgetContent(waterMl: Long?, goalMl: Long?, presets: List<ContainerPreset>) {
    Column(
        modifier = GlanceModifier.fillMaxSize().background(GlanceTheme.colors.background).padding(day.drome.app.R.dimen.widget_padding),
        verticalAlignment = Alignment.Vertical.CenterVertically,
    ) {
        Text("DROME", style = TextStyle(color = GlanceTheme.colors.onBackground, fontWeight = FontWeight.Bold))
        if (waterMl == null || goalMl == null) {
            Text("Open Drome to begin")
        } else {
            Text("${WaterUnits.ouncesFromMilliliters(waterMl).toInt()} / ${WaterUnits.ouncesFromMilliliters(goalMl).toInt()} fl oz")
            Row(GlanceModifier.fillMaxWidth(), horizontalAlignment = Alignment.Horizontal.CenterHorizontally) {
                presets.take(3).forEach { preset ->
                    Button(
                        text = "+${WaterUnits.ouncesFromMilliliters(preset.ml).toInt()}",
                        onClick = actionRunCallback<LogWaterCallback>(actionParametersOf(AmountKey to preset.ml)),
                    )
                }
            }
        }
    }
}

class LogWaterCallback : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val ml = parameters[AmountKey] ?: return
        withContext(Dispatchers.IO) { DromeCoreProvider.get(context).logWater(ml) }
        DromeWidget().updateAll(context)
    }
}
