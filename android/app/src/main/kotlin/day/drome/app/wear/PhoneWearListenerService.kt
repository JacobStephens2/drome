package day.drome.app.wear

import android.content.Context
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import androidx.glance.appwidget.updateAll
import day.drome.app.DromeCoreProvider
import day.drome.app.widget.DromeWidget
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

class PhoneWearListenerService : WearableListenerService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val receipts by lazy { getSharedPreferences("wear-receipts-v1", Context.MODE_PRIVATE) }

    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val path = event.dataItem.uri.path ?: continue
            if (!path.startsWith("/cmd/")) continue
            val map = DataMapItem.fromDataItem(event.dataItem).dataMap
            val id = map.getString("id") ?: path.removePrefix("/cmd/")
            scope.launch {
                runCatching {
                    if (!receipts.contains(id)) {
                        when (map.getString("kind")) {
                            "water" -> DromeCoreProvider.get(this@PhoneWearListenerService).logExternalWater(
                                commandId = id,
                                ml = map.getLong("amount_ml"),
                                loggedAtEpoch = map.getLong("created_at_epoch"),
                                tzOffsetSecs = map.getInt("tz_offset_secs"),
                            )
                            else -> error("unknown Wear command")
                        }
                        // The DataItem path is immutable and unique. This durable receipt
                        // makes repeated callbacks no-ops before the ack is observed.
                        receipts.edit().putLong(id, System.currentTimeMillis()).commit()
                    }
                    val ack = PutDataMapRequest.create("/ack/$id").apply {
                        dataMap.putString("id", id)
                        dataMap.putLong("acked_at_epoch_ms", System.currentTimeMillis())
                    }.asPutDataRequest().setUrgent()
                    Wearable.getDataClient(this@PhoneWearListenerService).putDataItem(ack).await()
                    DromeWidget().updateAll(this@PhoneWearListenerService)
                }
            }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
