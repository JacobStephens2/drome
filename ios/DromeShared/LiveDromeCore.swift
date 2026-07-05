//
//  LiveDromeCore.swift
//  DromeShared
//
//  DromeCoreClient backed by the real Rust core via the UniFFI bindings in
//  Generated/drome_core.swift. ONLY this file (and Generated/) may reference
//  the generated types — views and AppModel use the Swift-native Models types.
//
//  Generated types carry a `Uni` prefix (see core/uniffi.toml) so they can
//  coexist with Models.swift inside the same module. This class:
//    - stamps `LocalInstant` from Date() + TimeZone.current at every call
//      (the core is clock-free; views never pass time),
//    - maps generated records <-> Models structs field by field,
//    - translates the core's flat UniDromeError into the Models DromeError.
//

import Foundation

final class LiveDromeCore: DromeCoreClient, @unchecked Sendable {

    private let store: DromeStore

    /// Opens (or creates) the SQLite store at `dbPath` (WAL mode, set by the core).
    init(dbPath: String) throws {
        do {
            store = try DromeStore.open(dbPath: dbPath)
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - Time stamping (the facade owns the clock)

    private static func nowInstant() -> LocalInstant {
        let now = Date()
        return LocalInstant(
            epochSecs: Int64(now.timeIntervalSince1970.rounded(.down)),
            tzOffsetSecs: Int32(TimeZone.current.secondsFromGMT(for: now))
        )
    }

    /// Local "YYYY-MM-DD" for right now under the given day cutoff (mirrors the
    /// core's step-2 attribution; used only to default NewChallenge.startDate).
    ///
    /// Exactly the core's math (time.rs `attribute_date` step 2): wall seconds
    /// from ONE captured instant, minus the cutoff, floor-divided into epoch
    /// days. No DateFormatter/Calendar timezone involvement — shifting a Date
    /// and formatting in the current zone would apply the offset in effect at
    /// (now − cutoff), diverging from the core across a DST transition.
    private static func localDate(cutoffMinutes: Int) -> DayDate {
        let now = nowInstant()
        let wallSecs = now.epochSecs + Int64(now.tzOffsetSecs) - Int64(cutoffMinutes) * 60
        return dateString(fromEpochDays: floorDiv(wallSecs, 86_400))
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Civil-from-days (Howard Hinnant's algorithm), matching the core's
    /// chrono-backed date-from-epoch-days. Pure integer math.
    private static func dateString(fromEpochDays epochDays: Int64) -> DayDate {
        let z = epochDays + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097                                        // [0, 146096]
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365 // [0, 399]
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)                  // [0, 365]
        let mp = (5 * doy + 2) / 153                                       // [0, 11]
        let day = doy - (153 * mp + 2) / 5 + 1                             // [1, 31]
        let month = mp < 10 ? mp + 3 : mp - 9                              // [1, 12]
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: - Error translation

    private static func translate(_ error: Error) -> Error {
        guard let e = error as? UniDromeError else { return error }
        switch e {
        case .Database(let m): return DromeError.storage(m)
        case .Serialization(let m): return DromeError.storage(m)
        case .Internal(let m): return DromeError.storage(m)
        case .InvalidDate(let m): return DromeError.invalidDate(m)
        case .InvalidArgument(let m): return DromeError.invalidArgument(m)
        case .TimeOutOfRange(let m): return DromeError.invalidArgument(m)
        case .NoActiveChallenge: return DromeError.noActiveChallenge
        case .ActiveChallengeExists: return DromeError.challengeAlreadyActive
        case .EventNotFound(let m): return DromeError.notFound(m)
        case .UnknownExtra(let m): return DromeError.notFound(m)
        }
    }

    private func call<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: - DromeCoreClient: challenge lifecycle

    func activeChallenge() throws -> Challenge? {
        try call { try store.activeChallenge().map(Self.challenge) }
    }

    @discardableResult
    func createChallenge(_ cfg: NewChallenge) throws -> Challenge {
        let uni = UniNewChallenge(
            ruleset: Self.rulesetKind(cfg.ruleset),
            startDate: cfg.startDate ?? Self.localDate(cutoffMinutes: cfg.dayCutoffMinutes),
            lengthDays: UInt32(clamping: cfg.lengthDays),
            dayCutoffMinutes: UInt32(clamping: cfg.dayCutoffMinutes),
            wakingStartMinutes: UInt32(clamping: cfg.wakingStartMinutes),
            wakingEndMinutes: UInt32(clamping: cfg.wakingEndMinutes),
            initialWaterGoalMl: cfg.initialWaterGoalMl,
            dietDescription: cfg.dietDescription.isEmpty ? nil : cfg.dietDescription,
            currentBook: cfg.currentBook.isEmpty ? nil : cfg.currentBook,
            createdAt: Self.nowInstant()
        )
        return try call { Self.challenge(try store.createChallenge(cfg: uni)) }
    }

    // MARK: - DromeCoreClient: config

    func containerPresets() throws -> [ContainerPreset] {
        try call { try store.containerPresets().map(Self.preset) }
    }

    func updatePresets(_ presets: [ContainerPreset]) throws {
        try call { try store.updatePresets(presets: presets.map(Self.uniPreset)) }
    }

    func extraDefs() throws -> [ExtraDef] {
        try call { try store.extraDefs().map(Self.extraDef) }
    }

    func setExtraEnabled(id: String, enabled: Bool) throws {
        try call { try store.setExtraEnabled(extraId: id, enabled: enabled) }
    }

    func setCurrentBook(_ title: String) throws {
        try call { try store.setCurrentBook(title: title) }
    }

    func setWaterGoal(ml: Int64) throws {
        try call { try store.setWaterGoal(ml: ml, now: Self.nowInstant()) }
    }

    func setDietDescription(_ desc: String) throws {
        try call { try store.setDietDescription(desc: desc) }
    }

    func setWakingWindow(startMinutes: UInt16, endMinutes: UInt16) throws {
        try call { try store.setWakingWindow(startMinutes: startMinutes, endMinutes: endMinutes) }
    }

    // MARK: - DromeCoreClient: logging

    func logWater(ml: Int64, effectiveDate: DayDate?) throws -> LogResult {
        try call {
            Self.logResult(try store.logWater(ml: ml, now: Self.nowInstant(), effectiveDate: effectiveDate))
        }
    }

    func logWorkout(durationMin: Int, outdoor: Bool, note: String?, effectiveDate: DayDate?) throws -> LogResult {
        guard durationMin > 0 else { throw DromeError.invalidArgument("workout duration_min must be in 1..=1440") }
        return try call {
            Self.logResult(try store.logWorkout(
                durationMin: UInt32(clamping: durationMin),
                outdoor: outdoor,
                note: note,
                startedAt: nil,
                now: Self.nowInstant(),
                effectiveDate: effectiveDate
            ))
        }
    }

    func logReading(bookTitle: String, pages: Int, effectiveDate: DayDate?) throws -> LogResult {
        guard pages > 0 else { throw DromeError.invalidArgument("pages must be in 1..=10000") }
        // Fall back to the challenge's current book when no title is passed.
        var title = bookTitle
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = try call { try store.activeChallenge()?.currentBook ?? "" }
        }
        return try call {
            Self.logResult(try store.logReading(
                bookTitle: title,
                pages: UInt32(clamping: pages),
                now: Self.nowInstant(),
                effectiveDate: effectiveDate
            ))
        }
    }

    func logDietOk(effectiveDate: DayDate?) throws -> LogResult {
        try call {
            Self.logResult(try store.logDietOk(now: Self.nowInstant(), effectiveDate: effectiveDate))
        }
    }

    func logPhotoDone(photoRef: String?, effectiveDate: DayDate?) throws -> LogResult {
        try call {
            Self.logResult(try store.logPhotoDone(
                photoRef: photoRef, now: Self.nowInstant(), effectiveDate: effectiveDate
            ))
        }
    }

    func logExtraDone(extraId: String, effectiveDate: DayDate?) throws -> LogResult {
        try call {
            Self.logResult(try store.logExtraDone(
                extraId: extraId, now: Self.nowInstant(), effectiveDate: effectiveDate
            ))
        }
    }

    // MARK: - DromeCoreClient: day lifecycle, undo, backfill

    @discardableResult
    func closeDay(date: DayDate) throws -> DayState {
        try call { Self.dayState(try store.closeDay(date: date, now: Self.nowInstant())) }
    }

    func revokeEvent(eventUuid: String) throws {
        try call { try store.revokeEvent(eventUuid: eventUuid, now: Self.nowInstant()) }
    }

    func backfillDays(_ days: [BackfilledDay]) throws {
        try call { try store.backfillDays(days: days.map(Self.uniBackfilledDay), now: Self.nowInstant()) }
    }

    // MARK: - DromeCoreClient: projections

    func dayState(date: DayDate) throws -> DayState {
        try call { Self.dayState(try store.dayState(date: date, now: Self.nowInstant())) }
    }

    func today() throws -> TodayState {
        try call { Self.todayState(try store.today(now: Self.nowInstant())) }
    }

    func summary() throws -> ChallengeSummary {
        try call {
            guard let challenge = try store.activeChallenge() else {
                throw UniDromeError.NoActiveChallenge(message: "no active challenge")
            }
            let s = try store.summary(now: Self.nowInstant())
            // challengeId + ruleset are not part of the core summary record;
            // they come from the active challenge row.
            return ChallengeSummary(
                challengeId: challenge.id,
                ruleset: Self.ruleset(challenge.ruleset),
                startDate: s.startDate,
                lengthDays: Int(s.lengthDays),
                todayDayIndex: Int(s.todayDayIndex),
                daysCompleteCount: Int(s.daysCompleteCount),
                currentRun: Int(s.currentRun)
            )
        }
    }

    func calendar(from: DayDate, to: DayDate) throws -> [DayBrief] {
        try call {
            try store.calendar(fromDate: from, toDate: to, now: Self.nowInstant()).map(Self.dayBrief)
        }
    }

    func waterState() throws -> WaterState {
        try call { Self.waterState(try store.waterState(now: Self.nowInstant())) }
    }

    // MARK: - DromeCoreClient: water safety

    func checkChug(addMl: Int64) throws -> ChugCheck {
        try call { Self.chugCheck(try store.checkChug(now: Self.nowInstant(), addMl: addMl)) }
    }

    // MARK: - DromeCoreClient: sharing & export

    func shareCard(date: DayDate) throws -> ShareCardData {
        try call {
            let card = try store.shareCard(date: date, now: Self.nowInstant())
            // lengthDays is not part of the core share-card record.
            let lengthDays = try store.activeChallenge().map { Int($0.lengthDays) } ?? 75
            return Self.shareCardData(card, lengthDays: lengthDays)
        }
    }

    func exportJson() throws -> String {
        try call { try store.exportJson(now: Self.nowInstant()) }
    }

    func exportCsv() throws -> String {
        try call { try store.exportCsv(now: Self.nowInstant()) }
    }

    // MARK: - DromeCoreClient: restore

    /// Restores an `exportJson` snapshot. Only into a store with no active
    /// challenge (core-enforced); throws `DromeError.challengeAlreadyActive`.
    func importJson(_ snapshot: String) throws {
        try call { try store.importJson(snapshot: snapshot) }
    }
}

// MARK: - Generated <-> Models mapping

private extension LiveDromeCore {

    static func ruleset(_ r: RulesetKind) -> Ruleset {
        switch r {
        case .flexible: return .flexible
        case .purist: return .purist
        }
    }

    static func rulesetKind(_ r: Ruleset) -> RulesetKind {
        switch r {
        case .flexible: return .flexible
        case .purist: return .purist
        }
    }

    static func cadence(_ c: Cadence) -> ExtraCadence {
        switch c {
        case .daily: return .daily
        case .weekly: return .weekly
        }
    }

    static func challenge(_ c: UniChallenge) -> Challenge {
        Challenge(
            id: c.id,
            ruleset: ruleset(c.ruleset),
            startDate: c.startDate,
            lengthDays: Int(c.lengthDays),
            dayCutoffMinutes: Int(c.dayCutoffMinutes),
            wakingStartMinutes: Int(c.wakingStartMinutes),
            wakingEndMinutes: Int(c.wakingEndMinutes),
            initialWaterGoalMl: c.initialWaterGoalMl,
            dietDescription: c.dietDescription ?? "",
            currentBook: c.currentBook ?? "",
            active: c.active
        )
    }

    static func preset(_ p: UniContainerPreset) -> ContainerPreset {
        ContainerPreset(id: p.id, name: p.name, ml: p.ml, sortOrder: Int(p.sortOrder))
    }

    static func uniPreset(_ p: ContainerPreset) -> UniContainerPreset {
        UniContainerPreset(id: p.id, name: p.name, ml: p.ml, sortOrder: Int32(clamping: p.sortOrder))
    }

    static func extraDef(_ e: UniExtraDef) -> ExtraDef {
        ExtraDef(id: e.id, name: e.name, cadence: cadence(e.cadence), enabled: e.enabled)
    }

    static func uniBackfilledDay(_ d: BackfilledDay) -> UniBackfilledDay {
        UniBackfilledDay(
            date: d.date,
            water: d.water,
            outdoorWorkout: d.outdoorWorkout,
            secondWorkout: d.secondWorkout,
            reading: d.reading,
            diet: d.diet,
            photo: d.photo,
            extraIds: d.extraIds
        )
    }

    static func workoutEntry(_ w: UniWorkoutEntry) -> WorkoutEntry {
        // Models drops startedAt; the event UUID becomes the Identifiable id.
        WorkoutEntry(id: w.eventUuid, durationMin: Int(w.durationMin), outdoor: w.outdoor, note: w.note)
    }

    static func dayState(_ d: UniDayState) -> DayState {
        DayState(
            date: d.date,
            dayIndex: Int(d.dayIndex),
            outOfRange: !d.inRange,
            waterTotalMl: d.waterMl,
            waterGoalMl: d.waterGoalMl,
            waterDone: d.waterDone,
            outdoorWorkoutDone: d.outdoorWorkoutDone,
            secondWorkoutDone: d.secondWorkoutDone,
            workouts: d.workouts.map(workoutEntry),
            pagesRead: Int(d.readingPages),
            readingDone: d.readingDone,
            dietDone: d.dietDone,
            photoDone: d.photoDone,
            extrasDone: d.extrasDone,
            coreComplete: d.coreComplete,
            isClosed: d.isClosed,
            isBackfilled: d.isBackfilled
        )
    }

    static func waterState(_ w: UniWaterState) -> WaterState {
        WaterState(
            totalMl: w.totalMl,
            goalMl: w.goalMl,
            remainingMl: w.remainingMl,
            paceTargetMl: w.paceTargetMl,
            onPace: w.onPace,
            finalOunce: w.finalOunce,
            discourageCatchUp: w.discourageCatchUp
        )
    }

    static func chugCheck(_ c: UniChugCheck) -> ChugCheck {
        ChugCheck(shouldWarn: c.warn, trailingHourMl: c.trailing60minMl, addMl: c.addMl, limitMl: c.thresholdMl)
    }

    static func logResult(_ r: UniLogResult) -> LogResult {
        LogResult(
            eventUuid: r.eventUuid,
            dayState: dayState(r.dayState),
            dayBecameComplete: r.dayBecameComplete,
            weekExtraBecameComplete: r.weekExtraBecameComplete,
            chugWarning: r.chugWarning.map(chugCheck)
        )
    }

    static func weekExtraState(_ w: UniWeekExtraState) -> WeekExtraState {
        // today() only reports enabled extras, hence enabled: true. The core
        // does not report the completion date; doneOnDate stays nil with Live.
        WeekExtraState(
            extra: ExtraDef(id: w.extraId, name: w.name, cadence: cadence(w.cadence), enabled: true),
            doneThisWeek: w.done,
            doneOnDate: nil
        )
    }

    /// Week = 7-day block by day index (week 1 = days 1-7), Euclidean division
    /// so out-of-range (pre-start) day indexes behave like the core.
    static func weekIndex(forDayIndex dayIndex: Int64) -> Int {
        let n = dayIndex - 1
        let q = n >= 0 ? n / 7 : (n - 6) / 7
        return Int(q + 1)
    }

    static func todayState(_ t: UniTodayState) -> TodayState {
        TodayState(
            date: t.date,
            dayIndex: Int(t.dayIndex),
            weekIndex: weekIndex(forDayIndex: t.day.dayIndex),
            day: dayState(t.day),
            water: waterState(t.water),
            weekExtras: t.weekExtras.map(weekExtraState)
        )
    }

    static func dayBrief(_ b: UniDayBrief) -> DayBrief {
        DayBrief(
            date: b.date,
            dayIndex: Int(b.dayIndex),
            coreComplete: b.coreComplete,
            isBackfilled: b.isBackfilled,
            isClosed: b.isClosed,
            outOfRange: !b.inRange
        )
    }

    static func shareCardData(_ c: UniShareCardData, lengthDays: Int) -> ShareCardData {
        ShareCardData(
            date: c.date,
            dayIndex: Int(c.dayIndex),
            lengthDays: lengthDays,
            outOfRange: c.outOfRange,
            // Core emits the lowercase label ("flexible"); Models wants "Flexible".
            rulesetLabel: Ruleset(rawValue: c.rulesetLabel)?.label ?? c.rulesetLabel,
            coreComplete: c.coreComplete,
            currentRun: Int(c.currentRun),
            waterTotalMl: c.waterMl,
            waterGoalMl: c.waterGoalMl,
            waterDone: c.waterDone,
            outdoorWorkoutDone: c.outdoorWorkoutDone,
            secondWorkoutDone: c.secondWorkoutDone,
            pagesRead: Int(c.readingPages),
            readingDone: c.readingDone,
            dietDone: c.dietDone,
            photoDone: c.photoDone,
            // Core share workouts are duration + outdoor only (no UUID, no
            // note — notes are private); synthesize stable per-card ids.
            workouts: c.workouts.enumerated().map { idx, w in
                ShareWorkout(id: "\(c.date)-workout-\(idx)", durationMin: Int(w.durationMin), outdoor: w.outdoor)
            },
            isBackfilled: c.isBackfilled
        )
    }
}
