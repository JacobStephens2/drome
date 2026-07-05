//
//  Models.swift
//  DromeShared
//
//  Swift-native mirrors of the drome-core records pinned in docs/ARCHITECTURE.md
//  ("Core public API"). Views use ONLY these types. The bindings stage's
//  LiveDromeCore.swift maps UniFFI-generated types to/from these; nothing else
//  may import the generated bindings.
//

import Foundation

/// A calendar date in "YYYY-MM-DD" form, exactly as the core API uses it.
/// Day attribution (cutoff math, closed-day rollover) lives in the core; the
/// Swift layer treats these as opaque, ordered strings.
typealias DayDate = String

// MARK: - Units

/// Canonical water unit is milliliters; UI may display fluid ounces.
enum WaterUnits {
    static let mlPerFlOz: Double = 29.5735
    /// One gallon, per the contract's rounding (3785 ml).
    static let mlPerGallon: Int64 = 3785

    static func flOz(fromMl ml: Int64) -> Double {
        Double(ml) / mlPerFlOz
    }

    /// Upper bound for a single fl-oz → ml conversion (~50 L), far beyond any
    /// sane goal or single log. Keeps the Double → Int64 conversion total.
    static let maxFlOz: Double = 1700

    static func ml(fromFlOz oz: Double) -> Int64 {
        // `oz` can arrive straight from unbounded text fields: clamp NaN/∞/huge
        // values instead of trapping on the Int64 conversion.
        guard oz.isFinite else { return 0 }
        let clamped = min(max(oz, 0), maxFlOz)
        return Int64((clamped * mlPerFlOz).rounded())
    }
}

// MARK: - Ruleset & challenge config

enum Ruleset: String, Codable, Sendable, CaseIterable {
    /// Default. Missing a day never resets anything.
    case flexible
    /// Rules-as-written. Implemented in the core where cheap; NO UI in Phase 1.
    case purist

    /// Honest label for share cards.
    var label: String {
        switch self {
        case .flexible: return "Flexible"
        case .purist: return "Purist"
        }
    }
}

struct Challenge: Identifiable, Sendable, Hashable, Codable {
    var id: String
    var ruleset: Ruleset
    var startDate: DayDate
    var lengthDays: Int
    /// Minutes after midnight where the day boundary sits (default 240 = 4:00 AM).
    var dayCutoffMinutes: Int
    /// Waking window (minutes after midnight), used for water pacing only.
    var wakingStartMinutes: Int
    var wakingEndMinutes: Int
    var initialWaterGoalMl: Int64
    var dietDescription: String
    var currentBook: String
    var active: Bool
}

/// Config for `createChallenge`. `startDate` may be a past date (backfill flow).
struct NewChallenge: Sendable, Hashable, Codable {
    var startDate: DayDate?
    var ruleset: Ruleset = .flexible
    var lengthDays: Int = 75
    var dayCutoffMinutes: Int = 240
    var wakingStartMinutes: Int = 420
    var wakingEndMinutes: Int = 1320
    var initialWaterGoalMl: Int64 = WaterUnits.mlPerGallon
    var dietDescription: String = ""
    var currentBook: String = ""
}

struct ContainerPreset: Identifiable, Sendable, Hashable, Codable {
    var id: String
    var name: String
    var ml: Int64
    var sortOrder: Int
}

enum ExtraCadence: String, Codable, Sendable {
    case daily
    case weekly
}

struct ExtraDef: Identifiable, Sendable, Hashable, Codable {
    var id: String
    var name: String
    var cadence: ExtraCadence
    var enabled: Bool
}

// MARK: - Core tasks & day state

/// The five tiles / six slots of a flexible-mode day. Weekly extras are NOT
/// core tasks and never gate `coreComplete`.
enum CoreTask: String, CaseIterable, Identifiable, Sendable {
    case water
    case outdoorWorkout
    case secondWorkout
    case reading
    case diet
    case photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .water: return "Water"
        case .outdoorWorkout: return "Outdoor workout"
        case .secondWorkout: return "Second workout"
        case .reading: return "Reading"
        case .diet: return "Diet"
        case .photo: return "Progress photo"
        }
    }
}

struct WorkoutEntry: Identifiable, Sendable, Hashable, Codable {
    /// Event UUID (usable with `revokeEvent`).
    var id: String
    var durationMin: Int
    var outdoor: Bool
    var note: String?
}

/// Projection of a single day. Always computed, never stored authoritatively.
struct DayState: Identifiable, Sendable, Hashable {
    var date: DayDate
    /// Days since start_date + 1; day 1 = start_date.
    var dayIndex: Int
    /// True when `dayIndex` falls outside [1, lengthDays].
    var outOfRange: Bool

    var waterTotalMl: Int64
    /// Goal as of this day (goal changes never rewrite the past).
    var waterGoalMl: Int64
    var waterDone: Bool
    var outdoorWorkoutDone: Bool
    var secondWorkoutDone: Bool
    var workouts: [WorkoutEntry]
    var pagesRead: Int
    var readingDone: Bool
    var dietDone: Bool
    var photoDone: Bool
    /// IDs of extras completed on this date (informational; extras never gate).
    var extrasDone: [String]

    /// All six core slots done.
    var coreComplete: Bool
    var isClosed: Bool
    var isBackfilled: Bool

    var id: DayDate { date }

    func isDone(_ task: CoreTask) -> Bool {
        switch task {
        case .water: return waterDone
        case .outdoorWorkout: return outdoorWorkoutDone
        case .secondWorkout: return secondWorkoutDone
        case .reading: return readingDone
        case .diet: return dietDone
        case .photo: return photoDone
        }
    }
}

// MARK: - Today / summary / history

/// State of a weekly extra within the current 7-day block (week 1 = days 1–7).
struct WeekExtraState: Identifiable, Sendable, Hashable {
    var extra: ExtraDef
    var doneThisWeek: Bool
    /// Date it was completed, when done.
    var doneOnDate: DayDate?

    var id: String { extra.id }
}

struct TodayState: Sendable, Hashable {
    var date: DayDate
    var dayIndex: Int
    /// 1-based 7-day block index (week 1 = days 1–7).
    var weekIndex: Int
    var day: DayState
    var water: WaterState
    var weekExtras: [WeekExtraState]
}

struct ChallengeSummary: Sendable, Hashable {
    var challengeId: String
    var ruleset: Ruleset
    var startDate: DayDate
    var lengthDays: Int
    var todayDayIndex: Int
    var daysCompleteCount: Int
    /// Consecutive complete days ending at today-if-complete, else yesterday.
    var currentRun: Int
}

/// Compact per-day row for the backfill grid and history calendar.
struct DayBrief: Identifiable, Sendable, Hashable {
    var date: DayDate
    var dayIndex: Int
    var coreComplete: Bool
    var isBackfilled: Bool
    var isClosed: Bool
    var outOfRange: Bool

    var id: DayDate { date }
}

// MARK: - Water pacing & safety

struct WaterState: Sendable, Hashable {
    var totalMl: Int64
    var goalMl: Int64
    var remainingMl: Int64
    /// Goal × elapsed fraction of the waking window, clamped to [0, goal].
    var paceTargetMl: Int64
    /// total ≥ paceTarget − 250 ml.
    var onPace: Bool
    /// 0 < remaining ≤ 150 ml — the "drink that final ounce" nudge.
    var finalOunce: Bool
    /// Within 90 min of waking_end AND remaining > 1000 ml. UI must show the
    /// anti-chug message and never cheer late-night catch-up.
    var discourageCatchUp: Bool
}

/// Anti-chug guard result. Ships in every mode; not configurable off.
struct ChugCheck: Sendable, Hashable {
    /// True when trailing-hour intake + the pending add exceeds `limitMl`.
    var shouldWarn: Bool
    /// Milliliters logged in the trailing 60 minutes.
    var trailingHourMl: Int64
    /// The add being evaluated.
    var addMl: Int64
    /// The safety threshold (1000 ml per trailing hour).
    var limitMl: Int64
}

// MARK: - Log results & sharing

struct LogResult: Sendable, Hashable {
    var eventUuid: String
    var dayState: DayState
    /// Fires the completion moment exactly once (core compares pre/post state).
    var dayBecameComplete: Bool
    var weekExtraBecameComplete: Bool
    var chugWarning: ChugCheck?
}

/// A workout as it appears on a share card: duration + outdoor flag ONLY.
/// Workout notes are private and never leave the device on a card.
struct ShareWorkout: Identifiable, Sendable, Hashable {
    /// Stable per-card id (synthesized by the mappings; cards carry no UUIDs).
    var id: String
    var durationMin: Int
    var outdoor: Bool
}

/// Everything a share card renders. Never contains photo refs or workout
/// notes. Per-task done flags come straight from the core so backfilled days
/// (whose flags carry no quantities) still render honestly.
struct ShareCardData: Sendable, Hashable {
    var date: DayDate
    /// Clamped to [1, lengthDays] by the core; `outOfRange` carries the truth.
    var dayIndex: Int
    var lengthDays: Int
    /// True when the date falls outside the challenge window — the card must
    /// say so rather than masquerade as an in-challenge day.
    var outOfRange: Bool
    /// Honest ruleset label ("Flexible" / "Purist").
    var rulesetLabel: String
    var coreComplete: Bool
    var currentRun: Int
    var waterTotalMl: Int64
    var waterGoalMl: Int64
    var waterDone: Bool
    var outdoorWorkoutDone: Bool
    var secondWorkoutDone: Bool
    var pagesRead: Int
    var readingDone: Bool
    var dietDone: Bool
    var photoDone: Bool
    var workouts: [ShareWorkout]
    var isBackfilled: Bool
}

// MARK: - Backfill

/// One backfilled day; flags mark tasks complete directly.
struct BackfilledDay: Sendable, Hashable, Codable {
    var date: DayDate
    var water: Bool
    var outdoorWorkout: Bool
    var secondWorkout: Bool
    var reading: Bool
    var diet: Bool
    var photo: Bool
    var extraIds: [String]
}

// MARK: - Errors

/// Swift-side mirror of the core's `DromeError`.
enum DromeError: Error, Sendable, Equatable {
    case noActiveChallenge
    case challengeAlreadyActive
    case invalidDate(String)
    case invalidArgument(String)
    case notFound(String)
    case storage(String)
}
