package day.drome.core

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncEngineTest {
    @Test fun signedOutIsAQuietNoOp() = runTest {
        var calls = 0
        val engine = SyncEngine(MockDromeCore(), SyncTransport { _, _ -> calls++; error("not called") }, AccessTokenProvider { null })
        assertTrue(!engine.syncNow("account:1"))
        assertEquals(0, calls)
    }

    @Test fun signedInRoundTripUsesCoreOwnedMerge() = runTest {
        var calls = 0
        val engine = SyncEngine(
            MockDromeCore(),
            SyncTransport { request, token ->
                calls++
                assertEquals("mock-device", request.deviceId)
                assertEquals("token", token)
                SyncNetworkResponse(emptyList(), emptyList(), 1, false, "{}", null)
            },
            AccessTokenProvider { "token" },
        )
        assertTrue(engine.syncNow("account:1"))
        assertEquals(1, calls)
    }

    @Test fun waterUnitRoundTripIsWithinOneMilliliter() {
        val ml = WaterUnits.millilitersFromOunces(16.0)
        assertTrue(kotlin.math.abs(WaterUnits.ouncesFromMilliliters(ml) - 16.0) < .04)
    }
}
