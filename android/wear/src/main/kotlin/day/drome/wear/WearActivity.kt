package day.drome.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.launch

class WearActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                val outbox = remember { WearOutbox(applicationContext) }
                val scope = rememberCoroutineScope()
                var pending by remember { mutableIntStateOf(outbox.pending().size) }
                fun add(ml: Long) {
                    outbox.enqueueWater(ml)
                    pending = outbox.pending().size
                    scope.launch { runCatching { outbox.publishPending() } }
                }
                LaunchedEffect(Unit) { runCatching { outbox.publishPending() } }
                Column(
                    Modifier.fillMaxSize().padding(horizontal = 18.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("DROME", fontWeight = FontWeight.Black)
                    Text(if (pending == 0) "Phone is caught up" else "$pending waiting for phone")
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                        Button(onClick = { add(355) }) { Text("12") }
                        Button(onClick = { add(473) }) { Text("16") }
                        Button(onClick = { add(710) }) { Text("24") }
                    }
                    Text("fl oz", color = Color.LightGray)
                }
            }
        }
    }
}
