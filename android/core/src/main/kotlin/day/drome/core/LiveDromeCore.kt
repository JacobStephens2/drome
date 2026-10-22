package day.drome.core

import day.drome.core.generated.DromeStore
import day.drome.core.generated.NewChallenge
import day.drome.core.generated.SyncRoundResponse
import day.drome.core.generated.syncFollowUp as coreSyncFollowUp
import kotlinx.coroutines.ExecutorCoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.concurrent.Executors

/**
 * The only hand-written class that talks to UniFFI. A single-thread dispatcher
 * preserves mutation/result order, while Rust's connection mutex and SQLite WAL
 * protect independent app/widget processes that open the same database.
 */
class LiveDromeCore private constructor(
    private val store: DromeStore,
    private val dispatcher: ExecutorCoroutineDispatcher,
) : DromeCoreClient {

    companion object {
        fun open(databasePath: String): LiveDromeCore = LiveDromeCore(
            store = DromeStore.open(databasePath),
            dispatcher = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "drome-core").apply { isDaemon = true }
            }.asCoroutineDispatcher(),
        )
    }

    private fun now(): LocalInstant {
        val instant = Instant.now()
        val offset = ZoneId.systemDefault().rules.getOffset(instant).totalSeconds
        return LocalInstant(instant.epochSecond, offset)
    }

    private suspend fun <T> call(block: (DromeStore) -> T): T =
        withContext(dispatcher) { block(store) }

    override suspend fun activeChallenge() = call { it.activeChallenge() }

    override suspend fun createChallenge(draft: ChallengeDraft): Challenge = call {
        val current = ZonedDateTime.now()
        val startDate = draft.startDate ?: current
            .minusMinutes(draft.dayCutoffMinutes.toLong())
            .toLocalDate()
            .toString()
        it.createChallenge(
            NewChallenge(
                ruleset = draft.ruleset,
                startDate = startDate,
                lengthDays = draft.lengthDays.coerceAtLeast(1).toUInt(),
                dayCutoffMinutes = draft.dayCutoffMinutes.coerceIn(0, 1_439).toUInt(),
                wakingStartMinutes = draft.wakingStartMinutes.coerceIn(0, 1_439).toUInt(),
                wakingEndMinutes = draft.wakingEndMinutes.coerceIn(1, 1_440).toUInt(),
                initialWaterGoalMl = draft.initialWaterGoalMl,
                dietDescription = draft.dietDescription.trim().ifEmpty { null },
                currentBook = draft.currentBook.trim().ifEmpty { null },
                createdAt = now(),
            ),
        )
    }

    override suspend fun containerPresets() = call { it.containerPresets() }
    override suspend fun updatePresets(presets: List<ContainerPreset>) = call { it.updatePresets(presets, now()) }
    override suspend fun extraDefs() = call { it.extraDefs() }
    override suspend fun setExtraEnabled(id: String, enabled: Boolean) = call { it.setExtraEnabled(id, enabled, now()) }
    override suspend fun setCurrentBook(title: String) = call { it.setCurrentBook(title, now()) }
    override suspend fun setWaterGoal(ml: Long) = call { it.setWaterGoal(ml, now()) }
    override suspend fun setDietDescription(description: String) = call { it.setDietDescription(description, now()) }
    override suspend fun setWakingWindow(startMinutes: Int, endMinutes: Int) = call {
        it.setWakingWindow(startMinutes.coerceIn(0, 1_439).toUShort(), endMinutes.coerceIn(1, 1_440).toUShort(), now())
    }
    override suspend fun setDayCutoff(minutes: Int) = call { it.setDayCutoff(minutes.coerceIn(0, 1_439).toUInt(), now()) }
    override suspend fun setStartDate(startDate: String) = call { it.setStartDate(startDate, now()) }

    override suspend fun today() = call { it.today(now()) }
    override suspend fun summary() = call { it.summary(now()) }
    override suspend fun dayState(date: String) = call { it.dayState(date, now()) }
    override suspend fun calendar(fromDate: String, toDate: String) = call { it.calendar(fromDate, toDate, now()) }
    override suspend fun waterState() = call { it.waterState(now()) }
    override suspend fun waterLog(date: String) = call { it.waterLog(date, now()) }

    override suspend fun logWater(ml: Long, effectiveDate: String?) = call { it.logWater(ml, now(), effectiveDate) }
    override suspend fun logExternalWater(commandId: String, ml: Long, loggedAtEpoch: Long, tzOffsetSecs: Int) = call {
        it.logWaterIdempotent(commandId, ml, LocalInstant(loggedAtEpoch, tzOffsetSecs))
    }
    override suspend fun adjustWater(negativeMl: Long, effectiveDate: String?) = call {
        it.logWaterAdjustment(negativeMl, now(), effectiveDate)
    }
    override suspend fun logWorkout(durationMinutes: Int, outdoor: Boolean, note: String?, effectiveDate: String?) = call {
        it.logWorkout(durationMinutes.coerceAtLeast(1).toUInt(), outdoor, note, null, now(), effectiveDate)
    }
    override suspend fun logReading(bookTitle: String, pages: Int, effectiveDate: String?) = call {
        it.logReading(bookTitle, pages.coerceAtLeast(1).toUInt(), now(), effectiveDate)
    }
    override suspend fun logDiet(effectiveDate: String?) = call { it.logDietOk(now(), effectiveDate) }
    override suspend fun logNoJunk(effectiveDate: String?) = call { it.logNoJunkOk(now(), effectiveDate) }
    override suspend fun logPhoto(photoRef: String?, effectiveDate: String?) = call { it.logPhotoDone(photoRef, now(), effectiveDate) }
    override suspend fun logExtra(id: String, effectiveDate: String?) = call { it.logExtraDone(id, now(), effectiveDate) }
    override suspend fun closeDay(date: String) = call { it.closeDay(date, now()) }
    override suspend fun revokeEvent(uuid: String) = call { it.revokeEvent(uuid, now()) }
    override suspend fun revokeTask(date: String, task: RevocableTask) = call { it.revokeTask(date, task, now()) }
    override suspend fun backfill(days: List<BackfilledDay>) = call { it.backfillDays(days, now()) }

    override suspend fun checkChug(addMl: Long) = call { it.checkChug(now(), addMl) }
    override suspend fun shareCard(date: String) = call { it.shareCard(date, now()) }
    override suspend fun exportJson() = call { it.exportJson(now()) }
    override suspend fun exportCsv() = call { it.exportCsv(now()) }
    override suspend fun importJson(snapshot: String) = call { it.importJson(snapshot) }
    override suspend fun resetAllData() = call { it.resetAllData() }

    override suspend fun prepareSync(context: String, limit: Int): CoreSyncPreparation = call {
        val prepared = it.prepareSyncRound(context, limit.toUInt())
        CoreSyncPreparation(
            resetEpoch = prepared.resetEpoch,
            deviceId = prepared.deviceId,
            lastServerSeq = prepared.lastServerSeq,
            events = prepared.pending,
            configJson = prepared.configJson,
        )
    }

    override suspend fun applySync(
        context: String,
        expectedResetEpoch: Long,
        ackedUuids: List<String>,
        remoteEvents: List<WireEvent>,
        newServerSeq: Long,
        configJson: String,
        winnerChallengeId: String?,
    ): SyncApplyResult = call {
        it.applySyncResponse(
            context,
            expectedResetEpoch,
            SyncRoundResponse(
                ackedUuids = ackedUuids,
                configJson = configJson,
                winnerChallengeId = winnerChallengeId,
                events = remoteEvents,
                newLastServerSeq = newServerSeq,
            ),
        )
    }

    override fun syncFollowUp(pushedCount: Int, pushLimit: Int, more: Boolean, outcome: SyncOutcome): Boolean =
        coreSyncFollowUp(pushedCount.toUInt(), pushLimit.toUInt(), more, outcome)

    override fun close() {
        store.close()
        dispatcher.close()
    }
}
