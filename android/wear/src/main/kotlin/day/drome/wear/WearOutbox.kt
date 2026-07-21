package day.drome.wear

import android.content.Context
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

data class WearCommand(
    val id: String,
    val kind: String,
    val amountMl: Long,
    val createdAtEpoch: Long,
    val tzOffsetSecs: Int,
)

/**
 * Persist-before-send outbox. A successful DataClient write means accepted by
 * the durable Data Layer, not delivered; only a phone ack removes the row.
 */
class WearOutbox(context: Context) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("wear-outbox-v1", Context.MODE_PRIVATE)

    @Synchronized
    fun enqueueWater(amountMl: Long): WearCommand {
        val instant = Instant.now()
        val offset = java.time.ZoneId.systemDefault().rules.getOffset(instant).totalSeconds
        val command = WearCommand(UUID.randomUUID().toString(), "water", amountMl, instant.epochSecond, offset)
        prefs.edit().putString(command.id, command.toJson().toString()).commit()
        return command
    }

    @Synchronized
    fun pending(): List<WearCommand> = prefs.all.values.mapNotNull { raw ->
        runCatching { JSONObject(raw as String).toCommand() }.getOrNull()
    }.sortedBy { it.createdAtEpoch }

    @Synchronized fun acknowledge(id: String) { prefs.edit().remove(id).commit() }

    suspend fun publishPending() = withContext(Dispatchers.IO) {
        pending().forEach { command ->
            val request = PutDataMapRequest.create("/cmd/${command.id}").apply {
                dataMap.putString("id", command.id)
                dataMap.putString("kind", command.kind)
                dataMap.putLong("amount_ml", command.amountMl)
                dataMap.putLong("created_at_epoch", command.createdAtEpoch)
                dataMap.putInt("tz_offset_secs", command.tzOffsetSecs)
            }.asPutDataRequest().setUrgent()
            Wearable.getDataClient(app).putDataItem(request).await()
        }
    }
}

private fun WearCommand.toJson() = JSONObject()
    .put("id", id)
    .put("kind", kind)
    .put("amount_ml", amountMl)
    .put("created_at_epoch", createdAtEpoch)
    .put("tz_offset_secs", tzOffsetSecs)

private fun JSONObject.toCommand() = WearCommand(
    getString("id"), getString("kind"), getLong("amount_ml"), getLong("created_at_epoch"), getInt("tz_offset_secs"),
)
