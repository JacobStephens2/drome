package day.drome.core

// Kotlin-facing names for UniFFI value records. The generated implementation
// stays isolated in this module; app and Wear code import day.drome.core only.
typealias BackfilledDay = day.drome.core.generated.BackfilledDay
typealias Cadence = day.drome.core.generated.Cadence
typealias Challenge = day.drome.core.generated.Challenge
typealias ChallengeSummary = day.drome.core.generated.ChallengeSummary
typealias ChugCheck = day.drome.core.generated.ChugCheck
typealias ContainerPreset = day.drome.core.generated.ContainerPreset
typealias DayBrief = day.drome.core.generated.DayBrief
typealias DayState = day.drome.core.generated.DayState
typealias DromeException = day.drome.core.generated.DromeException
typealias ExtraDef = day.drome.core.generated.ExtraDef
typealias LocalInstant = day.drome.core.generated.LocalInstant
typealias LogResult = day.drome.core.generated.LogResult
typealias RevocableTask = day.drome.core.generated.RevocableTask
typealias RevocableTasks = day.drome.core.generated.RevocableTasks
typealias RulesetKind = day.drome.core.generated.RulesetKind
typealias ShareCardData = day.drome.core.generated.ShareCardData
typealias ShareCardWorkout = day.drome.core.generated.ShareCardWorkout
typealias SyncApplyResult = day.drome.core.generated.SyncApplyResult
typealias SyncOutcome = day.drome.core.generated.SyncOutcome
typealias TodayState = day.drome.core.generated.TodayState
typealias WaterLogEntry = day.drome.core.generated.WaterLogEntry
typealias WaterState = day.drome.core.generated.WaterState
typealias WeekExtraState = day.drome.core.generated.WeekExtraState
typealias WireEvent = day.drome.core.generated.WireEvent
typealias WorkoutEntry = day.drome.core.generated.WorkoutEntry

object CoreTasks {
    val Diet: RevocableTask = day.drome.core.generated.RevocableTask.Diet
    val NoJunk: RevocableTask = day.drome.core.generated.RevocableTask.NoJunk
    val Photo: RevocableTask = day.drome.core.generated.RevocableTask.Photo
    val Reading: RevocableTask = day.drome.core.generated.RevocableTask.Reading
    fun extra(id: String): RevocableTask = day.drome.core.generated.RevocableTask.Extra(id)
}

data class ChallengeDraft(
    val startDate: String? = null,
    val ruleset: RulesetKind = RulesetKind.FLEXIBLE,
    val lengthDays: Int = 75,
    val dayCutoffMinutes: Int = 240,
    val wakingStartMinutes: Int = 420,
    val wakingEndMinutes: Int = 1320,
    val initialWaterGoalMl: Long = 3_785,
    val dietDescription: String = "",
    val currentBook: String = "",
)

data class CoreSyncPreparation(
    val resetEpoch: Long,
    val deviceId: String,
    val lastServerSeq: Long,
    val events: List<WireEvent>,
    val configJson: String,
)

object WaterUnits {
    const val MILLILITERS_PER_GALLON = 3_785L
    private const val ML_PER_FL_OZ = 29.5735

    fun millilitersFromOunces(ounces: Double): Long =
        if (ounces.isFinite()) (ounces.coerceIn(0.0, 1_700.0) * ML_PER_FL_OZ).toLong() else 0L

    fun ouncesFromMilliliters(ml: Long): Double = ml / ML_PER_FL_OZ
}
