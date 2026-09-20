package day.drome.app

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import day.drome.core.ChallengeDraft
import day.drome.core.LiveDromeCore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class NativeCoreSmokeTest {
    @Test fun realSoOpensLogsProjectsAndExports() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val db = File(context.cacheDir, "native-smoke-${System.nanoTime()}.sqlite")
        LiveDromeCore.open(db.absolutePath).use { core ->
            core.createChallenge(ChallengeDraft(startDate = "2026-07-20"))
            val result = core.logWater(473)
            assertEquals(473, result.dayState.waterMl)
            assertNotNull(core.today())
            assertTrue(core.exportJson().contains("challenge"))
        }
    }
}
