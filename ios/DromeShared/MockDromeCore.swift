//
//  MockDromeCore.swift
//  DromeShared
//
//  Full in-memory DromeCoreClient with correct-enough flexible-mode logic for
//  demos, previews, and the view fan-out build stage. Seeded with the demo
//  fixture: 13 prior days (1–12 backfilled complete, day 13 complete except
//  reading — with water done via a PARTIAL backfill flag carrying no
//  quantities, so share-card previews exercise the flags-not-totals path) and
//  a partial day 14 = the REAL current date. The start date is anchored
//  13 days before "today" so the fixture always presents day 14; on
//  2026-07-04 that start date is exactly 2026-06-21 per the contract.
//
//  Replaced at integration time by LiveDromeCore (UniFFI bindings). Keep the
//  observable behavior aligned with docs/ARCHITECTURE.md.
//

import Foundation

final class MockDromeCore: DromeCoreClient, @unchecked Sendable {

    // MARK: - Internal event model

    private enum EventKind {
        case water(ml: Int64)
        /// Signed correction; ml is always negative (see logWaterAdjustment).
        case waterAdjust(ml: Int64)
        case workout(durationMin: Int, outdoor: Bool, note: String?)
        case reading(book: String, pages: Int)
        case dietOk
        case noJunkOk
        case photoDone(ref: String?)
        case extraDone(id: String)
        case backfill(BackfilledDay)
    }

    private struct Event {
        let uuid: String
        let date: DayDate
        let kind: EventKind
        let loggedAt: Date
        /// True when the log carried an explicit effectiveDate (retroactive).
        var retro = false
        var revoked = false
    }

    // MARK: - State (guarded by `lock`)

    private let lock = NSLock()
    private var challenge: Challenge
    private var presets: [ContainerPreset]
    private var extras: [ExtraDef]
    private var events: [Event] = []
    private var closedDates: Set<DayDate> = []
    /// Water-goal changes as (firstEffectiveDate, ml); past days keep old goals.
    private var goalChanges: [(date: DayDate, ml: Int64)] = []

    private let calendar: Calendar
    private let dayFormatter: DateFormatter

    // MARK: - Init & demo fixture

    init(now: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        calendar = cal

        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        dayFormatter = f

        // Today per the 4:00 AM cutoff; start anchored so today is day 14.
        let cutoffMinutes = 240
        let todayDate = f.string(from: now.addingTimeInterval(TimeInterval(-cutoffMinutes * 60)))
        let startDate = Self.shift(todayDate, by: -13, formatter: f, calendar: cal)

        challenge = Challenge(
            id: "mock-challenge",
            ruleset: .flexible,
            startDate: startDate,
            lengthDays: 75,
            dayCutoffMinutes: cutoffMinutes,
            wakingStartMinutes: 420,
            wakingEndMinutes: 1320,
            initialWaterGoalMl: WaterUnits.mlPerGallon,
            dietDescription: "no junk, no alcohol",
            currentBook: "Atomic Habits",
            active: true
        )
        presets = [
            ContainerPreset(id: "bottle-32oz", name: "32 oz bottle", ml: 946, sortOrder: 0),
            ContainerPreset(id: "glass", name: "Glass", ml: 350, sortOrder: 1),
        ]
        extras = [
            ExtraDef(id: "job_application", name: "Apply to a job", cadence: .weekly, enabled: true),
        ]

        // Days 1–12: backfilled complete (job application done in week 1, day 5).
        for offset in 0..<12 {
            let date = Self.shift(startDate, by: offset, formatter: f, calendar: cal)
            let day = BackfilledDay(
                date: date, water: true, outdoorWorkout: true, secondWorkout: true,
                reading: true, diet: true, noJunk: true, photo: true,
                extraIds: offset == 4 ? ["job_application"] : []
            )
            events.append(Event(uuid: UUID().uuidString, date: date, kind: .backfill(day),
                                loggedAt: now.addingTimeInterval(-48 * 3600)))
        }

        // Day 13 (yesterday): everything except reading. Not closed — editable.
        // Water is done via a PARTIAL backfill flag (no quantities) while the
        // rest is event-logged: a partially-backfilled day, so share cards must
        // read the core's done flags, not recompute done-ness from totals.
        let day13 = Self.shift(startDate, by: 12, formatter: f, calendar: cal)
        let y = { (h: Double) in now.addingTimeInterval(-24 * 3600 + h * 3600) }
        events.append(Event(
            uuid: UUID().uuidString, date: day13,
            kind: .backfill(BackfilledDay(
                date: day13, water: true, outdoorWorkout: false, secondWorkout: false,
                reading: false, diet: false, noJunk: false, photo: false, extraIds: []
            )),
            loggedAt: y(-10)
        ))
        events.append(Event(uuid: UUID().uuidString, date: day13,
                            kind: .workout(durationMin: 45, outdoor: true, note: "Morning run"), loggedAt: y(-9)))
        events.append(Event(uuid: UUID().uuidString, date: day13,
                            kind: .workout(durationMin: 30, outdoor: false, note: "Lifting"), loggedAt: y(-2)))
        events.append(Event(uuid: UUID().uuidString, date: day13, kind: .dietOk, loggedAt: y(1)))
        // No-junk attested alongside diet (they're separate peer tasks).
        events.append(Event(uuid: UUID().uuidString, date: day13, kind: .noJunkOk, loggedAt: y(1.1)))
        events.append(Event(uuid: UUID().uuidString, date: day13, kind: .photoDone(ref: nil), loggedAt: y(1.2)))

        // Day 14 (today): two default-bottle pours (~half the gallon) + one
        // outdoor workout, hours ago so the trailing-hour chug window starts empty.
        events.append(Event(uuid: UUID().uuidString, date: todayDate, kind: .water(ml: 946),
                            loggedAt: now.addingTimeInterval(-5 * 3600)))
        events.append(Event(uuid: UUID().uuidString, date: todayDate, kind: .water(ml: 946),
                            loggedAt: now.addingTimeInterval(-2.5 * 3600)))
        events.append(Event(uuid: UUID().uuidString, date: todayDate,
                            kind: .workout(durationMin: 35, outdoor: true, note: "Morning walk"),
                            loggedAt: now.addingTimeInterval(-4 * 3600)))
    }

    // MARK: - Date helpers

    private static func shift(_ date: DayDate, by days: Int, formatter: DateFormatter, calendar: Calendar) -> DayDate {
        guard let base = formatter.date(from: date),
              let shifted = calendar.date(byAdding: .day, value: days, to: base) else { return date }
        return formatter.string(from: shifted)
    }

    private func shift(_ date: DayDate, by days: Int) -> DayDate {
        Self.shift(date, by: days, formatter: dayFormatter, calendar: calendar)
    }

    /// "Today" per the day-cutoff rule (a 1:30 AM moment belongs to yesterday).
    private func currentDate(_ now: Date) -> DayDate {
        dayFormatter.string(from: now.addingTimeInterval(TimeInterval(-challenge.dayCutoffMinutes * 60)))
    }

    private func dayIndex(of date: DayDate) -> Int {
        guard let start = dayFormatter.date(from: challenge.startDate),
              let day = dayFormatter.date(from: date),
              let delta = calendar.dateComponents([.day], from: start, to: day).day else { return 0 }
        return delta + 1
    }

    /// Attribution for a nil-effectiveDate log: today, unless today is already
    /// closed, in which case the next date (the "logged after closing" rule).
    private func attributedDate(effectiveDate: DayDate?, now: Date) -> DayDate {
        if let explicit = effectiveDate { return explicit }
        let today = currentDate(now)
        return closedDates.contains(today) ? shift(today, by: 1) : today
    }

    private func goal(asOf date: DayDate) -> Int64 {
        goalChanges.filter { $0.date <= date }.last?.ml ?? challenge.initialWaterGoalMl
    }

    // MARK: - Projections (call with lock held)

    private func computeDayState(date: DayDate) -> DayState {
        var waterMl: Int64 = 0
        var workouts: [WorkoutEntry] = []
        var pages = 0
        var diet = false
        var noJunk = false
        var photo = false
        var extrasDone: [String] = []
        var backfilled: BackfilledDay?

        for event in events where event.date == date && !event.revoked {
            switch event.kind {
            case .water(let ml), .waterAdjust(let ml):
                // Fold with a running floor like the core: a correction can
                // never consume more than the water logged before it, so an
                // orphaned correction (its add revoked later) clips at 0
                // instead of silently swallowing later pours.
                waterMl = max(0, waterMl + ml)
            case .workout(let durationMin, let outdoor, let note):
                workouts.append(WorkoutEntry(id: event.uuid, durationMin: durationMin, outdoor: outdoor, note: note))
            case .reading(_, let p): pages += p
            case .dietOk: diet = true
            case .noJunkOk: noJunk = true
            case .photoDone: photo = true
            case .extraDone(let id): extrasDone.append(id)
            case .backfill(let day): backfilled = day
            }
        }

        let goalMl = goal(asOf: date)
        let waterDone = waterMl >= goalMl || backfilled?.water == true
        let outdoorDone = workouts.contains { $0.outdoor } || backfilled?.outdoorWorkout == true
        let secondDone = workouts.count >= 2 || backfilled?.secondWorkout == true
        let readingDone = pages >= 10 || backfilled?.reading == true
        let dietDone = diet || backfilled?.diet == true
        let noJunkDone = noJunk || backfilled?.noJunk == true
        let photoDone = photo || backfilled?.photo == true
        // Revocability = a live event of the kind exists here, captured
        // BEFORE the backfill extras merge below — backfill flags are not
        // peelable events and never count (mirrors the core projection).
        let revocable = RevocableTasks(
            diet: diet,
            noJunk: noJunk,
            photo: photo,
            reading: pages > 0,
            extraIds: Array(Set(extrasDone)).sorted()
        )
        if let backfillExtras = backfilled?.extraIds {
            extrasDone.append(contentsOf: backfillExtras.filter { !extrasDone.contains($0) })
        }

        let index = dayIndex(of: date)
        return DayState(
            date: date,
            dayIndex: index,
            outOfRange: index < 1 || index > challenge.lengthDays,
            waterTotalMl: waterMl,
            waterGoalMl: goalMl,
            waterDone: waterDone,
            outdoorWorkoutDone: outdoorDone,
            secondWorkoutDone: secondDone,
            workouts: workouts,
            pagesRead: pages,
            readingDone: readingDone,
            dietDone: dietDone,
            noJunkDone: noJunkDone,
            photoDone: photoDone,
            extrasDone: extrasDone,
            revocable: revocable,
            coreComplete: waterDone && outdoorDone && secondDone && readingDone
                && dietDone && noJunkDone && photoDone,
            isClosed: closedDates.contains(date),
            isBackfilled: backfilled != nil
        )
    }

    private func computeWaterState(now: Date) -> WaterState {
        let today = currentDate(now)
        let state = computeDayState(date: today)
        let goalMl = state.waterGoalMl
        let total = state.waterTotalMl
        let remaining = max(0, goalMl - total)

        let minutesNow = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let windowStart = challenge.wakingStartMinutes
        let windowEnd = challenge.wakingEndMinutes
        let fraction = windowEnd > windowStart
            ? min(1.0, max(0.0, Double(minutesNow - windowStart) / Double(windowEnd - windowStart)))
            : 0.0
        let paceTarget = min(goalMl, max(0, Int64((Double(goalMl) * fraction).rounded())))
        let minutesToEnd = windowEnd - minutesNow

        return WaterState(
            totalMl: total,
            goalMl: goalMl,
            remainingMl: remaining,
            paceTargetMl: paceTarget,
            onPace: total >= paceTarget - 250,
            finalOunce: remaining > 0 && remaining <= 150,
            discourageCatchUp: minutesToEnd >= 0 && minutesToEnd <= 90 && remaining > 1000
        )
    }

    private func computeChug(now: Date, addMl: Int64) -> ChugCheck {
        let cutoff = now.addingTimeInterval(-3600)
        var trailing: Int64 = 0
        // Retroactive logs (explicit effectiveDate) are bookkeeping, not
        // current intake: they never enter the window. Live corrections net
        // against the pours logged BEFORE them, folded in time order with a
        // running floor at 0 (like the core), so an honest fat-finger fix
        // clears the false warning but a stale correction can never offset
        // intake logged after it — no manufactured chug headroom.
        for event in events.sorted(by: { $0.loggedAt < $1.loggedAt })
            where !event.revoked && !event.retro
            && event.loggedAt >= cutoff && event.loggedAt <= now {
            switch event.kind {
            case .water(let ml), .waterAdjust(let ml): trailing = max(0, trailing + ml)
            default: break
            }
        }
        let limit: Int64 = 1000
        return ChugCheck(shouldWarn: trailing + addMl > limit, trailingHourMl: trailing, addMl: addMl, limitMl: limit)
    }

    /// Week = 7-day block by day index (week 1 = days 1–7). Mirrors the
    /// core: prefers a date backed by a live event (revocable) over one
    /// satisfied only by a backfill flag, so the toggle-off targets a date
    /// where revokeTask would succeed whenever one exists.
    private func weekExtraDone(extraId: String, weekIndex: Int) -> DayDate? {
        let firstIndex = (weekIndex - 1) * 7 + 1
        var flagOnly: DayDate?
        for offset in 0..<7 {
            let date = shift(challenge.startDate, by: firstIndex - 1 + offset)
            let day = computeDayState(date: date)
            if day.revocable.extraIds.contains(extraId) { return date }
            if flagOnly == nil, day.extrasDone.contains(extraId) { flagOnly = date }
        }
        return flagOnly
    }

    private func computeWeekExtras(dayIndex: Int) -> [WeekExtraState] {
        let weekIndex = (dayIndex - 1) / 7 + 1
        return extras.filter { $0.enabled && $0.cadence == .weekly }.map { extra in
            let doneOn = weekIndex >= 1 ? weekExtraDone(extraId: extra.id, weekIndex: weekIndex) : nil
            return WeekExtraState(extra: extra, doneThisWeek: doneOn != nil, doneOnDate: doneOn)
        }
    }

    private func computeSummary(now: Date) -> ChallengeSummary {
        let todayIdx = dayIndex(of: currentDate(now))
        var completeCount = 0
        let lastCounted = min(max(todayIdx, 0), challenge.lengthDays)
        var completeByIndex: [Int: Bool] = [:]
        if lastCounted >= 1 {
            for idx in 1...lastCounted {
                let complete = computeDayState(date: shift(challenge.startDate, by: idx - 1)).coreComplete
                completeByIndex[idx] = complete
                if complete { completeCount += 1 }
            }
        }
        // Run ends at today-if-complete, else yesterday.
        var run = 0
        var cursor = (completeByIndex[todayIdx] == true) ? todayIdx : todayIdx - 1
        while cursor >= 1, completeByIndex[cursor] == true {
            run += 1
            cursor -= 1
        }
        return ChallengeSummary(
            challengeId: challenge.id,
            ruleset: challenge.ruleset,
            startDate: challenge.startDate,
            lengthDays: challenge.lengthDays,
            // Mirror the live core: the display index clamps to
            // [1, lengthDays]; the raw index carries the honest value.
            todayDayIndex: min(max(todayIdx, 1), challenge.lengthDays),
            todayRawDayIndex: todayIdx,
            daysCompleteCount: completeCount,
            currentRun: run
        )
    }

    // MARK: - Logging core (call with lock held)

    private func append(kind: EventKind, effectiveDate: DayDate?, now: Date, extraId: String? = nil) -> LogResult {
        let date = attributedDate(effectiveDate: effectiveDate, now: now)
        let before = computeDayState(date: date)
        let weekIndex = (dayIndex(of: date) - 1) / 7 + 1
        let extraDoneBefore = extraId.map { weekExtraDone(extraId: $0, weekIndex: weekIndex) != nil } ?? false

        let event = Event(uuid: UUID().uuidString, date: date, kind: kind, loggedAt: now,
                          retro: effectiveDate != nil)
        events.append(event)

        let after = computeDayState(date: date)
        let extraDoneAfter = extraId.map { weekExtraDone(extraId: $0, weekIndex: weekIndex) != nil } ?? false
        var chug: ChugCheck?
        if case .water(let ml) = kind, effectiveDate == nil {
            let check = computeChug(now: now, addMl: 0) // event already appended
            chug = ChugCheck(shouldWarn: check.trailingHourMl > check.limitMl,
                             trailingHourMl: max(0, check.trailingHourMl - ml),
                             addMl: ml,
                             limitMl: check.limitMl)
            if chug?.shouldWarn == false { chug = nil }
        }
        return LogResult(
            eventUuid: event.uuid,
            dayState: after,
            dayBecameComplete: !before.coreComplete && after.coreComplete,
            weekExtraBecameComplete: !extraDoneBefore && extraDoneAfter,
            chugWarning: chug
        )
    }

    // MARK: - DromeCoreClient: challenge lifecycle

    func activeChallenge() throws -> Challenge? {
        lock.lock(); defer { lock.unlock() }
        return challenge.active ? challenge : nil
    }

    @discardableResult
    func createChallenge(_ cfg: NewChallenge) throws -> Challenge {
        lock.lock(); defer { lock.unlock() }
        guard !challenge.active else { throw DromeError.challengeAlreadyActive }
        let now = Date()
        challenge = Challenge(
            id: UUID().uuidString,
            ruleset: cfg.ruleset,
            startDate: cfg.startDate ?? currentDate(now),
            lengthDays: cfg.lengthDays,
            dayCutoffMinutes: cfg.dayCutoffMinutes,
            wakingStartMinutes: cfg.wakingStartMinutes,
            wakingEndMinutes: cfg.wakingEndMinutes,
            initialWaterGoalMl: cfg.initialWaterGoalMl,
            dietDescription: cfg.dietDescription,
            currentBook: cfg.currentBook,
            active: true
        )
        events.removeAll()
        closedDates.removeAll()
        goalChanges.removeAll()
        return challenge
    }

    // MARK: - DromeCoreClient: config

    func containerPresets() throws -> [ContainerPreset] {
        lock.lock(); defer { lock.unlock() }
        return presets.sorted { $0.sortOrder < $1.sortOrder }
    }

    func updatePresets(_ newPresets: [ContainerPreset]) throws {
        lock.lock(); defer { lock.unlock() }
        presets = newPresets
    }

    func extraDefs() throws -> [ExtraDef] {
        lock.lock(); defer { lock.unlock() }
        return extras
    }

    func setExtraEnabled(id: String, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = extras.firstIndex(where: { $0.id == id }) else {
            throw DromeError.notFound("extra \(id)")
        }
        extras[idx].enabled = enabled
    }

    func setCurrentBook(_ title: String) throws {
        lock.lock(); defer { lock.unlock() }
        challenge.currentBook = title
    }

    func setWaterGoal(ml: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard ml > 0 else { throw DromeError.invalidArgument("water goal must be positive") }
        goalChanges.append((date: currentDate(Date()), ml: ml))
    }

    func setDietDescription(_ desc: String) throws {
        lock.lock(); defer { lock.unlock() }
        challenge.dietDescription = desc
    }

    func setWakingWindow(startMinutes: UInt16, endMinutes: UInt16) throws {
        guard startMinutes < endMinutes else {
            throw DromeError.invalidArgument("waking window must start before it ends")
        }
        lock.lock(); defer { lock.unlock() }
        challenge.wakingStartMinutes = Int(startMinutes)
        challenge.wakingEndMinutes = Int(endMinutes)
    }

    func setStartDate(_ startDate: DayDate) throws {
        lock.lock(); defer { lock.unlock() }
        challenge.startDate = startDate
    }

    func setDayCutoff(minutes: UInt32) throws {
        guard minutes < 1_440 else {
            throw DromeError.invalidArgument("day_cutoff_minutes must be in 0..=1439")
        }
        lock.lock(); defer { lock.unlock() }
        // The mock doesn't re-attribute past events (forward-only is a core
        // concern); surfacing the current cutoff is enough for UI/preview use.
        challenge.dayCutoffMinutes = Int(minutes)
    }

    // MARK: - DromeCoreClient: logging

    func logWater(ml: Int64, effectiveDate: DayDate?) throws -> LogResult {
        guard ml > 0 else { throw DromeError.invalidArgument("ml must be positive") }
        lock.lock(); defer { lock.unlock() }
        return append(kind: .water(ml: ml), effectiveDate: effectiveDate, now: Date())
    }

    func logWaterAdjustment(ml: Int64, effectiveDate: DayDate?) throws -> LogResult {
        guard (-10_000 ... -1).contains(ml) else {
            throw DromeError.invalidArgument("water adjustment ml must be in -10000 ... -1")
        }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        // Over-correction guard, mirroring the core: an adjustment may remove
        // at most the attributed day's current (floored) total.
        let date = attributedDate(effectiveDate: effectiveDate, now: now)
        let total = computeDayState(date: date).waterTotalMl
        guard -ml <= total else {
            throw DromeError.invalidArgument(
                "water adjustment of \(ml) ml exceeds the day's current total of \(total) ml"
            )
        }
        return append(kind: .waterAdjust(ml: ml), effectiveDate: effectiveDate, now: now)
    }

    func logWorkout(durationMin: Int, outdoor: Bool, note: String?, effectiveDate: DayDate?) throws -> LogResult {
        guard durationMin > 0 else { throw DromeError.invalidArgument("duration must be positive") }
        lock.lock(); defer { lock.unlock() }
        return append(kind: .workout(durationMin: durationMin, outdoor: outdoor, note: note),
                      effectiveDate: effectiveDate, now: Date())
    }

    func logReading(bookTitle: String, pages: Int, effectiveDate: DayDate?) throws -> LogResult {
        guard pages > 0 else { throw DromeError.invalidArgument("pages must be positive") }
        lock.lock(); defer { lock.unlock() }
        return append(kind: .reading(book: bookTitle, pages: pages), effectiveDate: effectiveDate, now: Date())
    }

    func logDietOk(effectiveDate: DayDate?) throws -> LogResult {
        lock.lock(); defer { lock.unlock() }
        return append(kind: .dietOk, effectiveDate: effectiveDate, now: Date())
    }

    func logNoJunkOk(effectiveDate: DayDate?) throws -> LogResult {
        lock.lock(); defer { lock.unlock() }
        return append(kind: .noJunkOk, effectiveDate: effectiveDate, now: Date())
    }

    func logPhotoDone(photoRef: String?, effectiveDate: DayDate?) throws -> LogResult {
        lock.lock(); defer { lock.unlock() }
        return append(kind: .photoDone(ref: photoRef), effectiveDate: effectiveDate, now: Date())
    }

    func logExtraDone(extraId: String, effectiveDate: DayDate?) throws -> LogResult {
        lock.lock(); defer { lock.unlock() }
        guard extras.contains(where: { $0.id == extraId }) else {
            throw DromeError.notFound("extra \(extraId)")
        }
        return append(kind: .extraDone(id: extraId), effectiveDate: effectiveDate, now: Date(), extraId: extraId)
    }

    // MARK: - DromeCoreClient: day lifecycle, undo, backfill

    @discardableResult
    func closeDay(date: DayDate) throws -> DayState {
        lock.lock(); defer { lock.unlock() }
        closedDates.insert(date)
        return computeDayState(date: date)
    }

    func revokeEvent(eventUuid: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let idx = events.firstIndex(where: { $0.uuid == eventUuid }) else {
            throw DromeError.notFound("event \(eventUuid)")
        }
        events[idx].revoked = true
    }

    @discardableResult
    func revokeTask(_ kind: RevocableTask, date: DayDate) throws -> LogResult {
        lock.lock(); defer { lock.unlock() }
        // Mirrors the core: attest kinds (diet/no-junk/photo/extra) are
        // idempotent, so ALL their live events on the date are revoked in
        // one call (the task genuinely flips off); reading is additive and
        // peels only the newest entry (`events` appends in log order,
        // mirroring the core's (logged_at, id) ordering). Backfill flags
        // never match: a flag is not a peelable event of the task's kind.
        let matching = events.indices.filter { idx in
            let event = events[idx]
            guard !event.revoked, event.date == date else { return false }
            switch (kind, event.kind) {
            case (.diet, .dietOk), (.noJunk, .noJunkOk), (.photo, .photoDone), (.reading, .reading):
                return true
            case (.extra(let id), .extraDone(let doneId)):
                return id == doneId
            default:
                return false
            }
        }
        let targets: [Int]
        if case .reading = kind {
            targets = Array(matching.suffix(1))
        } else {
            targets = matching
        }
        guard !targets.isEmpty else {
            throw DromeError.taskNotRevocable(
                "no live \(kind) event attributed to \(date) "
                    + "(backfill flags and empty days have nothing to revoke)"
            )
        }
        var revokedPhotoRefs: [String] = []
        for idx in targets.reversed() {
            events[idx].revoked = true
            if case .photo = kind, case .photoDone(let ref) = events[idx].kind, let ref {
                revokedPhotoRefs.append(ref)
            }
        }
        return LogResult(
            // The core returns the last appended `revoked` event's uuid; the
            // mock flags in place, so it synthesizes an equivalent opaque uuid.
            eventUuid: UUID().uuidString,
            dayState: computeDayState(date: date),
            // Hard-false: an undo never fires the completion/weekly moments.
            // They fire again, intentionally, on the log that re-completes.
            dayBecameComplete: false,
            weekExtraBecameComplete: false,
            chugWarning: nil,
            revokedPhotoRefs: revokedPhotoRefs
        )
    }

    func backfillDays(_ days: [BackfilledDay]) throws {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for day in days {
            events.append(Event(uuid: UUID().uuidString, date: day.date, kind: .backfill(day), loggedAt: now))
        }
    }

    // MARK: - DromeCoreClient: projections

    func dayState(date: DayDate) throws -> DayState {
        lock.lock(); defer { lock.unlock() }
        return computeDayState(date: date)
    }

    func today() throws -> TodayState {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let date = currentDate(now)
        let day = computeDayState(date: date)
        return TodayState(
            date: date,
            dayIndex: day.dayIndex,
            weekIndex: (day.dayIndex - 1) / 7 + 1,
            day: day,
            water: computeWaterState(now: now),
            weekExtras: computeWeekExtras(dayIndex: day.dayIndex)
        )
    }

    func summary() throws -> ChallengeSummary {
        lock.lock(); defer { lock.unlock() }
        return computeSummary(now: Date())
    }

    func calendar(from: DayDate, to: DayDate) throws -> [DayBrief] {
        lock.lock(); defer { lock.unlock() }
        guard from <= to else { throw DromeError.invalidDate("from > to") }
        var briefs: [DayBrief] = []
        var cursor = from
        while cursor <= to {
            let state = computeDayState(date: cursor)
            briefs.append(DayBrief(
                date: cursor,
                dayIndex: state.dayIndex,
                coreComplete: state.coreComplete,
                isBackfilled: state.isBackfilled,
                isClosed: state.isClosed,
                outOfRange: state.outOfRange
            ))
            cursor = shift(cursor, by: 1)
        }
        return briefs
    }

    func waterState() throws -> WaterState {
        lock.lock(); defer { lock.unlock() }
        return computeWaterState(now: Date())
    }

    /// Non-revoked water pours AND signed corrections attributed to `date`
    /// (the mock resolves attribution at append time), ordered by loggedAt
    /// ascending — the same entries `computeDayState` folds (its total
    /// applies a running floor at 0 per event, like the core).
    func waterLog(date: DayDate) throws -> [WaterLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return events
            .compactMap { event -> WaterLogEntry? in
                guard !event.revoked, event.date == date else { return nil }
                let ml: Int64
                switch event.kind {
                case .water(let m), .waterAdjust(let m): ml = m
                default: return nil
                }
                return WaterLogEntry(
                    id: event.uuid,
                    ml: ml,
                    loggedAt: event.loggedAt,
                    tzOffsetSecs: TimeZone.current.secondsFromGMT(for: event.loggedAt),
                    retro: event.retro
                )
            }
            .sorted { $0.loggedAt < $1.loggedAt }
    }

    // MARK: - DromeCoreClient: water safety

    func checkChug(addMl: Int64) throws -> ChugCheck {
        lock.lock(); defer { lock.unlock() }
        return computeChug(now: Date(), addMl: addMl)
    }

    // MARK: - DromeCoreClient: sharing & export

    func shareCard(date: DayDate) throws -> ShareCardData {
        lock.lock(); defer { lock.unlock() }
        let state = computeDayState(date: date)
        let summary = computeSummary(now: Date())
        return ShareCardData(
            date: date,
            // Like the core: clamped to [1, lengthDays]; outOfRange is honest.
            dayIndex: min(max(state.dayIndex, 1), challenge.lengthDays),
            lengthDays: challenge.lengthDays,
            outOfRange: state.outOfRange,
            rulesetLabel: challenge.ruleset.label,
            coreComplete: state.coreComplete,
            currentRun: summary.currentRun,
            waterTotalMl: state.waterTotalMl,
            waterGoalMl: state.waterGoalMl,
            waterDone: state.waterDone,
            outdoorWorkoutDone: state.outdoorWorkoutDone,
            secondWorkoutDone: state.secondWorkoutDone,
            pagesRead: state.pagesRead,
            readingDone: state.readingDone,
            dietDone: state.dietDone,
            noJunkDone: state.noJunkDone,
            photoDone: state.photoDone,
            // Cards carry duration + outdoor only — workout notes stay private.
            workouts: state.workouts.map {
                ShareWorkout(id: $0.id, durationMin: $0.durationMin, outdoor: $0.outdoor)
            },
            isBackfilled: state.isBackfilled
        )
    }

    /// Snapshot shape shared by `exportJson`/`importJson`. Events are not
    /// round-tripped by the mock (the real core exports its full event log).
    private struct Snapshot: Codable {
        var challenge: Challenge
        var presets: [ContainerPreset]
        var extras: [ExtraDef]
        var closedDates: [DayDate]
    }

    func exportJson() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let export = Snapshot(challenge: challenge, presets: presets, extras: extras,
                              closedDates: closedDates.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - DromeCoreClient: restore

    /// Mirrors the core's contract: only into a store with no active challenge.
    func importJson(_ snapshot: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !challenge.active else { throw DromeError.challengeAlreadyActive }
        guard let restored = try? JSONDecoder().decode(Snapshot.self, from: Data(snapshot.utf8)) else {
            throw DromeError.invalidArgument("that file isn't a Drome backup")
        }
        challenge = restored.challenge
        presets = restored.presets
        extras = restored.extras
        closedDates = Set(restored.closedDates)
        events.removeAll()
        goalChanges.removeAll()
    }

    // MARK: - DromeCoreClient: reset

    /// Mirrors the core's wipe: everything cleared, back to a NO-CHALLENGE
    /// state — deliberately NOT re-seeding the demo fixture (a reset lands
    /// on onboarding, like the real store). Previews that need the fixture
    /// construct a fresh MockDromeCore instead.
    func resetAllData() throws {
        lock.lock(); defer { lock.unlock() }
        challenge.active = false
        presets.removeAll()
        extras.removeAll()
        events.removeAll()
        closedDates.removeAll()
        goalChanges.removeAll()
        // Mirror the core's sync/reset epoch invariant: bump the reset
        // generation and zero the pull cursor, so any in-flight round-trip's
        // tail writes (carrying the pre-reset epoch) are recognized as stale.
        mockResetEpoch += 1
        mockLastServerSeq = 0
    }

    func exportCsv() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let todayIdx = dayIndex(of: currentDate(Date()))
        var rows = ["date,day,water_ml,water_goal_ml,outdoor_workout,second_workout,pages,diet,no_junk,photo,extras,complete,backfilled"]
        let lastIdx = min(max(todayIdx, 1), challenge.lengthDays)
        for idx in 1...lastIdx {
            let date = shift(challenge.startDate, by: idx - 1)
            let s = computeDayState(date: date)
            rows.append([
                date, String(idx), String(s.waterTotalMl), String(s.waterGoalMl),
                String(s.outdoorWorkoutDone), String(s.secondWorkoutDone), String(s.pagesRead),
                String(s.dietDone), String(s.noJunkDone), String(s.photoDone),
                s.extrasDone.joined(separator: "|"),
                String(s.coreComplete), String(s.isBackfilled),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - DromeCoreClient: sync (Phase 2)
    //
    // Stubs only. Sync is not a preview/UI surface; the real engine runs
    // against LiveDromeCore. These keep MockDromeCore conforming and behave
    // as a store that never has anything to sync (empty push, no-op pull).

    private let mockDeviceId = "mock-device"
    private var mockLastServerSeq: Int64 = 0
    private var mockResetEpoch: Int64 = 0

    func deviceId() throws -> String { mockDeviceId }

    func currentResetEpoch() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return mockResetEpoch
    }

    func pendingEvents(context: String, limit: UInt32) throws -> [WireEvent] { [] }

    @discardableResult
    func ackPushed(context: String, uuids: [String], expectedResetEpoch: Int64) throws
        -> SyncOutcome
    {
        lock.lock(); defer { lock.unlock() }
        return expectedResetEpoch == mockResetEpoch ? .applied : .staleReset
    }

    @discardableResult
    func applyRemoteEvents(_ events: [WireEvent]) throws -> UInt32 { 0 }

    func exportConfigState() throws -> String { "{}" }

    @discardableResult
    func applyRemoteConfig(_ blockJson: String, expectedResetEpoch: Int64) throws -> SyncOutcome {
        lock.lock(); defer { lock.unlock() }
        return expectedResetEpoch == mockResetEpoch ? .applied : .staleReset
    }

    func adoptActiveChallenge(blockJson: String, winnerChallengeId: String) throws {}

    func lastServerSeq(context: String) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return mockLastServerSeq
    }

    @discardableResult
    func setLastServerSeq(context: String, seq: Int64, expectedResetEpoch: Int64) throws
        -> SyncOutcome
    {
        lock.lock(); defer { lock.unlock() }
        guard expectedResetEpoch == mockResetEpoch else { return .staleReset }
        mockLastServerSeq = seq
        return .applied
    }

    @discardableResult
    func applyPullBatch(
        context: String,
        events: [WireEvent],
        newLastServerSeq: Int64,
        expectedResetEpoch: Int64
    ) throws -> PullResult {
        lock.lock(); defer { lock.unlock() }
        guard expectedResetEpoch == mockResetEpoch else {
            return PullResult(outcome: .staleReset, inserted: 0)
        }
        mockLastServerSeq = newLastServerSeq
        return PullResult(outcome: .applied, inserted: 0)
    }
}
