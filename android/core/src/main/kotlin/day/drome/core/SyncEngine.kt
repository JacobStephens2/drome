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
 * Platform-neutral sync coordinator. HTTP and credential refresh are injected;
 * reset-epoch validation and all merge behavior stay in Rust.
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
        do {
            val prepared = core.prepareSync(context)
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
            if (applied.pull.outcome == SyncOutcome.STALE_RESET || applied.config == SyncOutcome.STALE_RESET) {
                return@withLock false
            }
            rounds++
        } while (response.more && rounds < 20)
        true
    }
}
