package day.drome.app.health

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Duration
import java.time.Instant

data class ImportedWorkout(
    val healthConnectId: String,
    val durationMinutes: Int,
    val outdoorGuess: Boolean,
    val title: String?,
)

class HealthConnectImporter(private val context: Context) {
    val permission = HealthPermission.getReadPermission(ExerciseSessionRecord::class)

    fun availability(): Int = HealthConnectClient.getSdkStatus(context)

    suspend fun hasPermission(): Boolean =
        client().permissionController.getGrantedPermissions().contains(permission)

    /** Read-only and import-only; callers must present the outdoor guess for manual override. */
    suspend fun workoutsSince(start: Instant): List<ImportedWorkout> {
        val response = client().readRecords(
            ReadRecordsRequest(
                recordType = ExerciseSessionRecord::class,
                timeRangeFilter = TimeRangeFilter.between(start, Instant.now()),
                ascendingOrder = false,
            ),
        )
        return response.records.map { record ->
            val searchable = "${record.title.orEmpty()} ${record.notes.orEmpty()}".lowercase()
            ImportedWorkout(
                healthConnectId = record.metadata.id,
                durationMinutes = Duration.between(record.startTime, record.endTime).toMinutes().toInt().coerceAtLeast(1),
                // Health Connect does not guarantee route access. Use conservative
                // metadata/type language and require a user-confirmed override.
                outdoorGuess = listOf("outdoor", "hike", "trail").any(searchable::contains),
                title = record.title,
            )
        }
    }

    private fun client() = HealthConnectClient.getOrCreate(context)
}
