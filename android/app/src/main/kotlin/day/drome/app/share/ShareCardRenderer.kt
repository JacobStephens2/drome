package day.drome.app.share

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.core.content.FileProvider
import day.drome.core.ShareCardData
import day.drome.core.WaterUnits
import java.io.File

object ShareCardRenderer {
    fun share(context: Context, data: ShareCardData) {
        val width = 1080
        val height = 1920
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        canvas.drawColor(Color.rgb(243, 234, 216))

        paint.color = Color.rgb(28, 25, 23)
        paint.typeface = android.graphics.Typeface.DEFAULT_BOLD
        paint.textSize = 92f
        canvas.drawText("DROME", 84f, 150f, paint)
        paint.textSize = 70f
        canvas.drawText("Day ${data.dayIndex}", 84f, 285f, paint)
        paint.textSize = 38f
        canvas.drawText(data.rulesetLabel, 84f, 350f, paint)

        paint.color = if (data.coreComplete) Color.rgb(21, 128, 61) else Color.rgb(194, 65, 12)
        paint.textSize = 54f
        canvas.drawText(if (data.coreComplete) "DAY COMPLETE" else "WORK IN PROGRESS", 84f, 470f, paint)

        paint.color = Color.rgb(28, 25, 23)
        paint.textSize = 44f
        val rows = listOf(
            "Water" to "${WaterUnits.ouncesFromMilliliters(data.waterMl).toInt()} / ${WaterUnits.ouncesFromMilliliters(data.waterGoalMl).toInt()} fl oz",
            "Outdoor workout" to done(data.outdoorWorkoutDone),
            "Second workout" to done(data.secondWorkoutDone),
            "Reading" to "${data.readingPages} pages ${done(data.readingDone)}",
            "Diet" to done(data.dietDone),
            "No junk or alcohol" to done(data.noJunkDone),
            "Progress photo" to done(data.photoDone), // status only; no photo or ref ever enters this DTO
        )
        rows.forEachIndexed { index, (name, value) ->
            val y = 650f + index * 130f
            paint.typeface = android.graphics.Typeface.DEFAULT_BOLD
            canvas.drawText(name, 84f, y, paint)
            paint.typeface = android.graphics.Typeface.DEFAULT
            canvas.drawText(value, 84f, y + 58f, paint)
        }
        paint.typeface = android.graphics.Typeface.DEFAULT_BOLD
        paint.textSize = 48f
        canvas.drawText("${data.currentRun}-day current run", 84f, 1700f, paint)
        paint.typeface = android.graphics.Typeface.DEFAULT
        paint.textSize = 32f
        canvas.drawText("Honestly logged. No partial-credit celebration.", 84f, 1780f, paint)

        val dir = File(context.cacheDir, "share").also { it.mkdirs() }
        val file = File(dir, "drome-day-${data.dayIndex}.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        context.startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).apply {
                    type = "image/png"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                },
                "Share today",
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    private fun done(value: Boolean) = if (value) "✓" else "open"
}
