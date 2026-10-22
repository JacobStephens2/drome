package day.drome.core

interface DromeCoreClient : AutoCloseable {
    suspend fun activeChallenge(): Challenge?
    suspend fun createChallenge(draft: ChallengeDraft): Challenge

    suspend fun containerPresets(): List<ContainerPreset>
    suspend fun updatePresets(presets: List<ContainerPreset>)
    suspend fun extraDefs(): List<ExtraDef>
    suspend fun setExtraEnabled(id: String, enabled: Boolean)
    suspend fun setCurrentBook(title: String)
    suspend fun setWaterGoal(ml: Long)
    suspend fun setDietDescription(description: String)
    suspend fun setWakingWindow(startMinutes: Int, endMinutes: Int)
    suspend fun setDayCutoff(minutes: Int)
    suspend fun setStartDate(startDate: String)

    suspend fun today(): TodayState
    suspend fun summary(): ChallengeSummary
    suspend fun dayState(date: String): DayState
    suspend fun calendar(fromDate: String, toDate: String): List<DayBrief>
    suspend fun waterState(): WaterState
    suspend fun waterLog(date: String): List<WaterLogEntry>

    suspend fun logWater(ml: Long, effectiveDate: String? = null): LogResult
    suspend fun logExternalWater(commandId: String, ml: Long, loggedAtEpoch: Long, tzOffsetSecs: Int): LogResult
    suspend fun adjustWater(negativeMl: Long, effectiveDate: String? = null): LogResult
    suspend fun logWorkout(
        durationMinutes: Int,
        outdoor: Boolean,
        note: String? = null,
        effectiveDate: String? = null,
    ): LogResult
    suspend fun logReading(bookTitle: String, pages: Int, effectiveDate: String? = null): LogResult
    suspend fun logDiet(effectiveDate: String? = null): LogResult
    suspend fun logNoJunk(effectiveDate: String? = null): LogResult
    suspend fun logPhoto(photoRef: String? = null, effectiveDate: String? = null): LogResult
    suspend fun logExtra(id: String, effectiveDate: String? = null): LogResult
    suspend fun closeDay(date: String): DayState
    suspend fun revokeEvent(uuid: String)
    suspend fun revokeTask(date: String, task: RevocableTask): LogResult
    suspend fun backfill(days: List<BackfilledDay>)

    suspend fun checkChug(addMl: Long): ChugCheck
    suspend fun shareCard(date: String): ShareCardData
    suspend fun exportJson(): String
    suspend fun exportCsv(): String
    suspend fun importJson(snapshot: String)
    suspend fun resetAllData()

    suspend fun prepareSync(context: String, limit: Int = 500): CoreSyncPreparation
    suspend fun applySync(
        context: String,
        expectedResetEpoch: Long,
        ackedUuids: List<String>,
        remoteEvents: List<WireEvent>,
        newServerSeq: Long,
        configJson: String,
        winnerChallengeId: String? = null,
    ): SyncApplyResult

    /**
     * The only continuation decision. Production forwards to the core.
     * The preview mock returns false and does not encode the policy.
     */
    fun syncFollowUp(pushedCount: Int, pushLimit: Int, more: Boolean, outcome: SyncOutcome): Boolean
}
