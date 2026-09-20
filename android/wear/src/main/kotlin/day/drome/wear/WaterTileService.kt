@file:Suppress("DEPRECATION")

package day.drome.wear

import androidx.wear.tiles.ActionBuilders
import androidx.wear.tiles.DimensionBuilders
import androidx.wear.tiles.LayoutElementBuilders
import androidx.wear.tiles.ModifiersBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import androidx.wear.tiles.TimelineBuilders
import androidx.wear.tiles.material.Button
import androidx.wear.tiles.material.Text
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class WaterTileService : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> {
        val amount = when (requestParams.state?.lastClickableId) {
            "water-12" -> 355L
            "water-16" -> 473L
            "water-24" -> 710L
            else -> null
        }
        if (amount != null) {
            val outbox = WearOutbox(this)
            outbox.enqueueWater(amount) // persisted before this request returns
            scope.launch { runCatching { outbox.publishPending() } }
        }

        val buttons = LayoutElementBuilders.Row.Builder()
            .setWidth(DimensionBuilders.expand())
            .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
        listOf("12" to "water-12", "16" to "water-16", "24" to "water-24").forEach { (label, id) ->
            val click = ModifiersBuilders.Clickable.Builder()
                .setId(id)
                .setOnClick(ActionBuilders.LoadAction.Builder().build())
                .build()
            buttons.addContent(Button.Builder(this, click).setTextContent(label).setContentDescription("Add $label fluid ounces").build())
        }
        val pending = WearOutbox(this).pending().size
        val column = LayoutElementBuilders.Column.Builder()
            .setWidth(DimensionBuilders.expand())
            .setHeight(DimensionBuilders.expand())
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
            .addContent(Text.Builder(this, "Drome water").build())
            .addContent(buttons.build())
            .addContent(Text.Builder(this, if (pending == 0) "Phone caught up" else "$pending pending").build())
            .build()
        val layout = LayoutElementBuilders.Layout.Builder().setRoot(column).build()
        val timeline = TimelineBuilders.Timeline.Builder()
            .addTimelineEntry(TimelineBuilders.TimelineEntry.Builder().setLayout(layout).build())
            .build()
        return Futures.immediateFuture(
            TileBuilders.Tile.Builder().setResourcesVersion("1").setTimeline(timeline).setFreshnessIntervalMillis(60_000).build(),
        )
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
