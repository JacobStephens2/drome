package day.drome.app.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.input.pointer.pointerInput
import day.drome.app.DromeColors

/** Stable mascot API. The water layer is clipped to Jerome's silhouette. */
@Composable
fun JeromeView(
    fill: Float,
    celebrating: Boolean,
    modifier: Modifier = Modifier,
    onPour: (() -> Unit)? = null,
    onCorrect: (() -> Unit)? = null,
) {
    Canvas(
        modifier
            .fillMaxWidth()
            .aspectRatio(1.55f)
            .pointerInput(onPour, onCorrect) {
                var drag = 0f
                detectVerticalDragGestures(
                    onVerticalDrag = { _, amount -> drag += amount },
                    onDragEnd = {
                        if (drag < -48f) onPour?.invoke()
                        if (drag > 48f) onCorrect?.invoke()
                        drag = 0f
                    },
                )
            },
    ) {
        val w = size.width
        val h = size.height
        val camel = Path().apply {
            moveTo(w * .12f, h * .70f)
            cubicTo(w * .12f, h * .38f, w * .31f, h * .28f, w * .47f, h * .44f)
            cubicTo(w * .58f, h * .20f, w * .70f, h * .24f, w * .72f, h * .45f)
            lineTo(w * .80f, h * .45f)
            lineTo(w * .87f, h * .12f)
            lineTo(w * .92f, h * .17f)
            lineTo(w * .89f, h * .50f)
            cubicTo(w * .95f, h * .57f, w * .93f, h * .70f, w * .86f, h * .72f)
            lineTo(w * .80f, h * .72f)
            lineTo(w * .80f, h * .95f)
            lineTo(w * .73f, h * .95f)
            lineTo(w * .72f, h * .72f)
            lineTo(w * .31f, h * .72f)
            lineTo(w * .28f, h * .95f)
            lineTo(w * .21f, h * .95f)
            lineTo(w * .22f, h * .70f)
            close()
        }
        drawPath(camel, DromeColors.Camel.copy(alpha = .28f))
        clipPath(camel) {
            val fraction = fill.coerceIn(0f, 1f)
            val top = h * (1f - fraction)
            drawRoundRect(
                color = DromeColors.Oasis,
                topLeft = Offset(0f, top),
                size = size.copy(height = h - top),
            )
        }
        drawPath(camel, DromeColors.Camel, style = androidx.compose.ui.graphics.drawscope.Stroke(w * .012f))
        drawCircle(Color.Black, w * .010f, Offset(w * .89f, h * .28f))
        if (celebrating) {
            repeat(8) { index ->
                val x = w * (.10f + index * .11f)
                val y = if (index % 2 == 0) h * .08f else h * .18f
                drawCircle(if (index % 2 == 0) DromeColors.Clay else DromeColors.Oasis, w * .012f, Offset(x, y))
            }
        }
    }
}
