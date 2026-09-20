package day.drome.app.reminders

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import day.drome.app.DromeCoreProvider
import day.drome.app.MainActivity
import day.drome.app.R
import day.drome.core.WaterUnits
import java.time.Duration
import java.time.ZonedDateTime
import java.util.concurrent.TimeUnit

object ReminderScheduler {
    private const val WorkName = "drome-deficit-reminder"

    /** Inexact by contract: Drome is not an alarm-clock app and requests no exact-alarm permission. */
    fun reschedule(context: Context) {
        val now = ZonedDateTime.now()
        var next = now.withHour(20).withMinute(0).withSecond(0).withNano(0)
        if (!next.isAfter(now)) next = next.plusDays(1)
        val delay = Duration.between(now, next).toMinutes().coerceAtLeast(1)
        val request = OneTimeWorkRequestBuilder<DeficitReminderWorker>()
            .setInitialDelay(delay, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(WorkName, ExistingWorkPolicy.REPLACE, request)
    }
}

class DeficitReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val today = runCatching { DromeCoreProvider.get(applicationContext).today() }.getOrNull()
            ?: return Result.success()
        if (!today.day.coreComplete) {
            val open = buildList {
                if (!today.day.waterDone) add("${WaterUnits.ouncesFromMilliliters(today.water.remainingMl).toInt()} oz water")
                if (!today.day.outdoorWorkoutDone || !today.day.secondWorkoutDone) add("workout")
                if (!today.day.readingDone) add("reading")
                if (!today.day.dietDone) add("diet")
                if (!today.day.noJunkDone) add("no-junk check")
                if (!today.day.photoDone) add("photo")
            }
            notify(applicationContext, "Still open: ${open.joinToString()}")
        }
        ReminderScheduler.reschedule(applicationContext)
        return Result.success()
    }

    private fun notify(context: Context, body: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel("deficits", "Challenge reminders", NotificationManager.IMPORTANCE_DEFAULT),
        )
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val pending = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        NotificationManagerCompat.from(context).notify(
            7501,
            NotificationCompat.Builder(context, "deficits")
                .setSmallIcon(R.drawable.ic_drome)
                .setContentTitle("Drome check-in")
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build(),
        )
    }
}

/** Kept as a manifest entry point for future explicit reminder actions. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = ReminderScheduler.reschedule(context)
}

class RescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = ReminderScheduler.reschedule(context)
}
