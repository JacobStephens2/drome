package day.drome.core

import java.util.UUID

/** Deterministic demo fixture used by previews and JVM ViewModel tests. */
class MockDromeCore : DromeCoreClient {
    private var challenge: Challenge? = Challenge(
        id = "demo-fixture",
        createdAt = LocalInstant(1_750_464_000, -14_400),
        ruleset = RulesetKind.FLEXIBLE,
        startDate = "2026-06-21",
        lengthDays = 75u,
        dayCutoffMinutes = 240u,
        wakingStartMinutes = 420u,
        wakingEndMinutes = 1320u,
        initialWaterGoalMl = 3_785,
        dietDescription = "Whole foods; no planned exceptions",
        currentBook = "The Boys in the Boat",
        active = true,
    )
    private var day = DayState(
        date = "2026-07-04", dayIndex = 14, inRange = true, isBackfilled = false, isClosed = false,
        waterMl = 1_892, waterGoalMl = 3_785, waterDone = false,
        workouts = listOf(WorkoutEntry("fixture-workout", 45u, true, "Morning walk", null)),
        outdoorWorkoutDone = true, secondWorkoutDone = false,
        readingPages = 0u, readingDone = false, dietDone = true, noJunkDone = true, photoDone = false,
        extrasDone = emptyList(),
        revocable = RevocableTasks(diet = true, noJunk = true, photo = false, reading = false, extraIds = emptyList()),
        coreComplete = false,
    )
    private val presets = mutableListOf(
        ContainerPreset("small", "12 oz", 355, 0),
        ContainerPreset("bottle", "16 oz", 473, 1),
        ContainerPreset("large", "24 oz", 710, 2),
    )

    override suspend fun activeChallenge() = challenge
    override suspend fun createChallenge(draft: ChallengeDraft): Challenge {
        challenge = checkNotNull(challenge).copy(
            ruleset = draft.ruleset,
            startDate = draft.startDate ?: "2026-07-04",
            lengthDays = draft.lengthDays.toUInt(),
            initialWaterGoalMl = draft.initialWaterGoalMl,
            dietDescription = draft.dietDescription,
            currentBook = draft.currentBook,
        )
        return checkNotNull(challenge)
    }
    override suspend fun containerPresets() = presets.toList()
    override suspend fun updatePresets(presets: List<ContainerPreset>) { this.presets.apply { clear(); addAll(presets) } }
    override suspend fun extraDefs() = emptyList<ExtraDef>()
    override suspend fun setExtraEnabled(id: String, enabled: Boolean) = Unit
    override suspend fun setCurrentBook(title: String) { challenge = challenge?.copy(currentBook = title) }
    override suspend fun setWaterGoal(ml: Long) { day = day.copy(waterGoalMl = ml); challenge = challenge?.copy(initialWaterGoalMl = ml) }
    override suspend fun setDietDescription(description: String) { challenge = challenge?.copy(dietDescription = description) }
    override suspend fun setWakingWindow(startMinutes: Int, endMinutes: Int) {
        challenge = challenge?.copy(wakingStartMinutes = startMinutes.toUInt(), wakingEndMinutes = endMinutes.toUInt())
    }
    override suspend fun setDayCutoff(minutes: Int) { challenge = challenge?.copy(dayCutoffMinutes = minutes.toUInt()) }
    override suspend fun setStartDate(startDate: String) { challenge = challenge?.copy(startDate = startDate) }

    override suspend fun today() = TodayState(day.date, 14u, false, day, waterState(), emptyList())
    override suspend fun summary() = ChallengeSummary(12u, 12u, 14u, false, 14, day.date, 27u, 14u, 120u, 47_000, "2026-06-21", 75u)
    override suspend fun dayState(date: String) = day.copy(date = date)
    override suspend fun calendar(fromDate: String, toDate: String) = (1L..14L).map { index ->
        DayBrief(if (index == 14L) day.date else "2026-06-${(20 + index).toString().padStart(2, '0')}", index, true, index <= 12, false, index < 14)
    }
    override suspend fun waterState() = WaterState(day.waterMl, day.waterGoalMl, (day.waterGoalMl - day.waterMl).coerceAtLeast(0), 1_800, true, false, false)
    override suspend fun waterLog(date: String) = emptyList<WaterLogEntry>()

    override suspend fun logWater(ml: Long, effectiveDate: String?) = result(day.copy(waterMl = day.waterMl + ml).also { day = it })
    override suspend fun logExternalWater(commandId: String, ml: Long, loggedAtEpoch: Long, tzOffsetSecs: Int) = logWater(ml)
    override suspend fun adjustWater(negativeMl: Long, effectiveDate: String?) = result(day.copy(waterMl = (day.waterMl + negativeMl).coerceAtLeast(0)).also { day = it })
    override suspend fun logWorkout(durationMinutes: Int, outdoor: Boolean, note: String?, effectiveDate: String?): LogResult {
        val workouts = day.workouts + WorkoutEntry(UUID.randomUUID().toString(), durationMinutes.toUInt(), outdoor, note, null)
        day = day.copy(workouts = workouts, outdoorWorkoutDone = workouts.any { it.outdoor }, secondWorkoutDone = workouts.size >= 2)
        return result(day)
    }
    override suspend fun logReading(bookTitle: String, pages: Int, effectiveDate: String?) = result(day.copy(readingPages = day.readingPages + pages.toUInt(), readingDone = true, revocable = day.revocable.copy(reading = true)).also { day = it })
    override suspend fun logDiet(effectiveDate: String?) = result(day.copy(dietDone = true, revocable = day.revocable.copy(diet = true)).also { day = it })
    override suspend fun logNoJunk(effectiveDate: String?) = result(day.copy(noJunkDone = true, revocable = day.revocable.copy(noJunk = true)).also { day = it })
    override suspend fun logPhoto(photoRef: String?, effectiveDate: String?) = result(day.copy(photoDone = true, revocable = day.revocable.copy(photo = true)).also { day = it })
    override suspend fun logExtra(id: String, effectiveDate: String?) = result(day.copy(extrasDone = day.extrasDone + id).also { day = it })
    override suspend fun closeDay(date: String) = day.copy(isClosed = true).also { day = it }
    override suspend fun revokeEvent(uuid: String) = Unit
    override suspend fun revokeTask(date: String, task: RevocableTask): LogResult = result(day)
    override suspend fun backfill(days: List<BackfilledDay>) = Unit
    override suspend fun checkChug(addMl: Long) = ChugCheck(addMl > 1_500, 0, addMl, 1_500)
    override suspend fun shareCard(date: String) = ShareCardData(date, 14u, false, "Flexible", day.coreComplete, false, 12u, day.waterMl, day.waterGoalMl, day.waterDone, day.outdoorWorkoutDone, day.secondWorkoutDone, day.readingPages, day.readingDone, day.dietDone, day.noJunkDone, day.photoDone, day.workouts.map { ShareCardWorkout(it.durationMin, it.outdoor) })
    override suspend fun exportJson() = "{\"fixture\":\"demo\"}"
    override suspend fun exportCsv() = "date,day_index\n${day.date},14\n"
    override suspend fun importJson(snapshot: String) = Unit
    override suspend fun resetAllData() { challenge = null }
    override suspend fun prepareSync(context: String, limit: Int) = CoreSyncPreparation(0, "mock-device", 0, emptyList(), "{}")
    override suspend fun applySync(context: String, expectedResetEpoch: Long, ackedUuids: List<String>, remoteEvents: List<WireEvent>, newServerSeq: Long, configJson: String, winnerChallengeId: String?) =
        CoreSyncApplication(PullResult(SyncOutcome.APPLIED, remoteEvents.size.toUInt()), SyncOutcome.APPLIED)
    override fun close() = Unit

    private fun result(state: DayState) = LogResult(UUID.randomUUID().toString(), state, false, false, null, emptyList())
}
