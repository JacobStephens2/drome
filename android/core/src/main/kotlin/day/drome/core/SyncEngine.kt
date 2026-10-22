package day.drome.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class SyncNetworkRequest(
    val deviceId: String,
    val lastServerSeq: Long,
    val events: List<WireEvent>,
    val configJson: String,
)

data class ActiveChallengeConflict(val archivedChallengeId: String, val winnerChallengeId: String)

data class SyncNetworkResponse(
    val ackedUuids: List<String>,
    val events: List<WireEvent>,
    val newLastServerSeq: Long,
    val more: Boolean,
    val configJson: String,
    val conflict: ActiveChallengeConflict?,
)

fun interface SyncTransport {
    suspend fun exchange(request: SyncNetworkRequest, accessToken: String): SyncNetworkResponse
}

fun interface AccessTokenProvider {
    suspend fun validAccessToken(): String?
}

/**
 * Platform-neutral sync coordinator. HTTP and credential refresh are injected.
 * Prepare, the tail, and the follow-up predicate stay in Rust. This loop is
 * the scheduling shape: at most 20 rounds, and a stale outcome prepares again
 * instead of waiting for the next log.
 */
class SyncEngine(
    private val core: DromeCoreClient,
    private val transport: SyncTransport,
    private val tokens: AccessTokenProvider,
) {
    private val gate = Mutex()

    suspend fun syncNow(context: String): Boolean = gate.withLock {
        val token = tokens.validAccessToken() ?: return@withLock false
        var rounds = 0
        var followUp: Boolean
        do {
            val prepared = core.prepareSync(context, PUSH_BATCH_LIMIT)
            val response = transport.exchange(
                SyncNetworkRequest(
                    deviceId = prepared.deviceId,
                    lastServerSeq = prepared.lastServerSeq,
                    events = prepared.events,
                    configJson = prepared.configJson,
                ),
                token,
            )
            val applied = core.applySync(
                context = context,
                expectedResetEpoch = prepared.resetEpoch,
                ackedUuids = response.ackedUuids,
                remoteEvents = response.events,
                newServerSeq = response.newLastServerSeq,
                configJson = response.configJson,
                winnerChallengeId = response.conflict?.winnerChallengeId,
            )
            rounds++
            followUp = core.syncFollowUp(
                pushedCount = prepared.events.size,
                pushLimit = PUSH_BATCH_LIMIT,
                more = response.more,
                outcome = applied.outcome,
            )
        } while (followUp && rounds < MAX_ROUNDS)
        true
    }

    private companion object {
        const val PUSH_BATCH_LIMIT = 500
        const val MAX_ROUNDS = 20
    }
}
