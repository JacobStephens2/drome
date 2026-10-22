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

    @Test fun followUpFalseStopsEvenWhenTheServerHasMoreAndAWinner() = runTest {
        val core = ScriptedSyncCore(
            outcomes = ArrayDeque(listOf(SyncOutcome.APPLIED)),
            followUps = ArrayDeque(listOf(false)),
        )
        var calls = 0
        val engine = SyncEngine(
            core,
            SyncTransport { _, _ ->
                calls++
                SyncNetworkResponse(
                    emptyList(),
                    emptyList(),
                    4,
                    true,
                    "{}",
                    ActiveChallengeConflict("loser", "winner"),
                )
            },
            AccessTokenProvider { "token" },
        )
        assertTrue(engine.syncNow("account:1"))
        assertEquals(1, calls)
        assertEquals(1, core.prepares)
        assertEquals(
            listOf(FollowUpCall(pushedCount = 0, pushLimit = 500, more = true, outcome = SyncOutcome.APPLIED)),
            core.followUpCalls,
        )
    }

    @Test fun staleFollowUpPreparesAgain() = runTest {
        val core = ScriptedSyncCore(
            outcomes = ArrayDeque(listOf(SyncOutcome.STALE_RESET, SyncOutcome.APPLIED)),
            followUps = ArrayDeque(listOf(true, false)),
        )
        var calls = 0
        val engine = SyncEngine(
            core,
            SyncTransport { _, _ ->
                calls++
                SyncNetworkResponse(emptyList(), emptyList(), 1, false, "{}", null)
            },
            AccessTokenProvider { "token" },
        )
        assertTrue(engine.syncNow("account:1"))
        assertEquals(2, calls)
        assertEquals(2, core.prepares)
        assertEquals(SyncOutcome.STALE_RESET, core.followUpCalls[0].outcome)
        assertEquals(false, core.followUpCalls[0].more)
    }

    @Test fun followUpStopsAtTwentyRounds() = runTest {
        val core = ScriptedSyncCore(
            outcomes = ArrayDeque(),
            followUps = ArrayDeque(),
            keepFollowing = true,
        )
        var calls = 0
        val engine = SyncEngine(
            core,
            SyncTransport { _, _ ->
                calls++
                SyncNetworkResponse(emptyList(), emptyList(), 1, true, "{}", null)
            },
            AccessTokenProvider { "token" },
        )
        assertTrue(engine.syncNow("account:1"))
        assertEquals(20, calls)
        assertEquals(20, core.prepares)
    }

    @Test fun waterUnitRoundTripIsWithinOneMilliliter() {
        val ml = WaterUnits.millilitersFromOunces(16.0)
        assertTrue(kotlin.math.abs(WaterUnits.ouncesFromMilliliters(ml) - 16.0) < .04)
    }
}

private data class FollowUpCall(
    val pushedCount: Int,
    val pushLimit: Int,
    val more: Boolean,
    val outcome: SyncOutcome,
)

private class ScriptedSyncCore(
    private val outcomes: ArrayDeque<SyncOutcome>,
    private val followUps: ArrayDeque<Boolean>,
    private val keepFollowing: Boolean = false,
) : MockDromeCore() {
    var prepares = 0
    val followUpCalls = mutableListOf<FollowUpCall>()

    override suspend fun prepareSync(context: String, limit: Int): CoreSyncPreparation {
        prepares++
        return super.prepareSync(context, limit)
    }

    override suspend fun applySync(
        context: String,
        expectedResetEpoch: Long,
        ackedUuids: List<String>,
        remoteEvents: List<WireEvent>,
        newServerSeq: Long,
        configJson: String,
        winnerChallengeId: String?,
    ): SyncApplyResult {
        val outcome = if (outcomes.isEmpty()) SyncOutcome.APPLIED else outcomes.removeFirst()
        return SyncApplyResult(outcome, 0u)
    }

    override fun syncFollowUp(pushedCount: Int, pushLimit: Int, more: Boolean, outcome: SyncOutcome): Boolean {
        followUpCalls += FollowUpCall(pushedCount, pushLimit, more, outcome)
        if (followUps.isEmpty()) return keepFollowing
        return followUps.removeFirst()
    }
}
