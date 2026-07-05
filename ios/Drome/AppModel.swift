//
//  AppModel.swift
//  Drome
//
//  App-wide observable state. Owns the DromeCoreClient facade, caches the
//  projections views render from, and exposes intent methods. Views never
//  talk to the core directly and never pass "now" — implementations stamp
//  time internally (docs/ARCHITECTURE.md, "Swift layer contracts").
//
//  Views that need a facade parameter AppModel doesn't wrap (setCurrentBook,
//  photoRef, calendar, shareCard, …) use the read-only `client` — the SAME
//  instance backing this model — and feed any LogResult back through
//  `noteExternalLog` so completion moments and refreshes stay centralized.
//

import Foundation
import Observation
import WidgetKit

/// One-shot payload for the daily completion moment. Carries the day that
/// actually flipped complete (retroactive "yesterday" logs celebrate the day
/// they finished, not today) and the run as of that instant.
struct CompletionMoment: Equatable, Identifiable {
    var dayIndex: Int
    var currentRun: Int

    var id: Int { dayIndex }
}

/// One-shot payload for the (deliberately smaller) weekly-extra moment.
struct WeeklyMoment: Equatable {
    var weekIndex: Int
    var extraName: String
}

@MainActor
@Observable
final class AppModel {

    // MARK: - Core client

    /// The facade. Read-only outside the model; views that take `client:`
    /// (ReadingView, PhotoView, SettingsView, HistoryView) MUST receive this
    /// same instance. Production composition (LiveDromeCore) happens in
    /// DromeApp; the default keeps previews on the in-memory mock.
    let client: DromeCoreClient

    init(core: DromeCoreClient = MockDromeCore()) {
        self.client = core
    }

    // MARK: - Cached projections

    private(set) var challenge: Challenge?
    private(set) var todayState: TodayState?
    private(set) var summary: ChallengeSummary?
    private(set) var waterState: WaterState?
    private(set) var presets: [ContainerPreset] = []

    /// Set once when a log flips a day to fully complete; the UI presents
    /// CompletionMomentView and clears this afterwards.
    var pendingCompletionMoment: CompletionMoment?

    /// Set when a weekly extra completes for its week. Always junior to the
    /// daily moment: the UI presents it only while no daily moment is pending
    /// (it queues here until the daily one is dismissed).
    var pendingWeeklyMoment: WeeklyMoment?

    /// Set when a water log would breach the anti-chug guard. The UI must
    /// surface this and only log after `confirmPendingWater()`.
    var pendingChugWarning: ChugCheck?

    /// Yesterday's projection (today − 1), refreshed alongside today. Drives
    /// the "log for yesterday" affordance: per the contract, yesterday stays
    /// editable until it's closed.
    private(set) var yesterdayState: DayState?

    /// Most recent user-visible error, if any. Set on every failed intent and
    /// surfaced as an alert at the RootView level; cleared ONLY by explicit
    /// dismissal (`clearLastError`) — a later successful refresh must never
    /// swallow an error the user hasn't seen.
    private(set) var lastErrorMessage: String?

    func clearLastError() {
        lastErrorMessage = nil
    }

    private var pendingWaterMl: Int64?

    /// Most recent today-attributed water event logged through this model.
    /// WaterView's "Undo last" revokes exactly this — never an arbitrary
    /// event of another kind. Cleared when that event is revoked.
    private(set) var lastWaterEventUuid: String?

    /// Most recent today-attributed diet attest, for DietView's immediate
    /// undo. Same targeted contract as `lastWaterEventUuid`.
    private(set) var lastDietEventUuid: String?

    /// The core's per-log water cap; retroactive "met goal" adds are chunked
    /// to stay under it, and WaterView clamps its drag-pour preview to it
    /// (goals may legally exceed it, so goal − total alone can overshoot).
    static let maxWaterPerLogMl: Int64 = 10_000

    // MARK: - Refresh

    func refresh() {
        do {
            challenge = try client.activeChallenge()
            guard challenge != nil else {
                todayState = nil
                summary = nil
                waterState = nil
                presets = []
                yesterdayState = nil
                lastWaterEventUuid = nil
                lastDietEventUuid = nil
                lastErrorMessage = nil
                return
            }
            todayState = try client.today()
            summary = try client.summary()
            waterState = try client.waterState()
            presets = try client.containerPresets()
            // Yesterday is best-effort: its failure never blocks the board.
            if let today = todayState?.date, let yesterday = Self.shift(today, by: -1) {
                yesterdayState = try? client.dayState(date: yesterday)
            } else {
                yesterdayState = nil
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    // MARK: - Water intents (anti-chug flow)

    /// Checks the anti-chug guard first. If the add would warn, stores it as
    /// pending, sets `pendingChugWarning`, and returns the check WITHOUT
    /// logging; the UI must ask for explicit confirmation. Otherwise logs
    /// immediately and returns nil.
    @discardableResult
    func checkThenLogWater(ml: Int64) -> ChugCheck? {
        do {
            let check = try client.checkChug(addMl: ml)
            if check.shouldWarn {
                pendingWaterMl = ml
                pendingChugWarning = check
                return check
            }
            let result = try client.logWater(ml: ml, effectiveDate: nil)
            lastWaterEventUuid = result.eventUuid
            handle(result)
            WidgetPaceCheck.clear()
            return nil
        } catch {
            lastErrorMessage = "\(error)"
            return nil
        }
    }

    /// Explicit user confirmation of a warned water log. Never celebrated.
    /// Also clears a widget-raised pace-check flag — the user has now seen
    /// the full dialog in the app.
    func confirmPendingWater() {
        guard let ml = pendingWaterMl else { return }
        pendingWaterMl = nil
        pendingChugWarning = nil
        do {
            let result = try client.logWater(ml: ml, effectiveDate: nil)
            lastWaterEventUuid = result.eventUuid
            handle(result)
            WidgetPaceCheck.clear()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    func cancelPendingWater() {
        pendingWaterMl = nil
        pendingChugWarning = nil
    }

    func logWater(ml: Int64) {
        checkThenLogWater(ml: ml)
    }

    func logWater(preset: ContainerPreset) {
        checkThenLogWater(ml: preset.ml)
    }

    /// Signed water correction (drag DOWN on Jerome): lowers today's recorded
    /// water. `ml` is negative-only by the facade contract; decreasing intake
    /// needs no safety gate, so this deliberately skips the chug
    /// check-then-confirm flow and logs immediately. The UI clamps to the
    /// day's current total; the core still enforces the over-correction
    /// guard, and a residual failure surfaces via `lastErrorMessage`.
    /// Tracked as the last water event so "Undo last" takes back the
    /// correction (revoking it restores the water) rather than revoking an
    /// older, unrelated pour.
    func logWaterAdjustment(ml: Int64) {
        guard ml < 0 else { return }
        do {
            let result = try client.logWaterAdjustment(ml: ml, effectiveDate: nil)
            lastWaterEventUuid = result.eventUuid
            handle(result)
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Retroactive water log ("log for yesterday"). Skips the anti-chug
    /// pre-check on purpose: the water was drunk on the effective day, not in
    /// the trailing hour, so a warning here would be dishonest. Large adds
    /// (a "met goal" tap with a >10 L goal) are chunked to respect the core's
    /// per-log cap; a residual failure surfaces via `lastErrorMessage`.
    /// Retroactive events deliberately don't touch `lastWaterEventUuid` —
    /// WaterView's "Undo last" is scoped to today's logs.
    func logWater(ml: Int64, effectiveDate: DayDate?) {
        guard let effectiveDate else {
            checkThenLogWater(ml: ml)
            return
        }
        var remaining = ml
        do {
            while remaining > 0 {
                let chunk = min(remaining, Self.maxWaterPerLogMl)
                handle(try client.logWater(ml: chunk, effectiveDate: effectiveDate))
                remaining -= chunk
            }
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    // MARK: - Other logging intents (effectiveDate nil = today)

    func logWorkout(durationMin: Int, outdoor: Bool, note: String? = nil, effectiveDate: DayDate? = nil) {
        run { try client.logWorkout(durationMin: durationMin, outdoor: outdoor, note: note, effectiveDate: effectiveDate) }
    }

    /// Pages against the challenge's current book.
    func logReading(pages: Int, effectiveDate: DayDate? = nil) {
        let book = challenge?.currentBook ?? ""
        run { try client.logReading(bookTitle: book, pages: pages, effectiveDate: effectiveDate) }
    }

    func logDietOk(effectiveDate: DayDate? = nil) {
        do {
            let result = try client.logDietOk(effectiveDate: effectiveDate)
            if effectiveDate == nil { lastDietEventUuid = result.eventUuid }
            handle(result)
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    func logPhotoDone(effectiveDate: DayDate? = nil) {
        run { try client.logPhotoDone(photoRef: nil, effectiveDate: effectiveDate) }
    }

    func logExtraDone(id: String, effectiveDate: DayDate? = nil) {
        do {
            let result = try client.logExtraDone(extraId: id, effectiveDate: effectiveDate)
            if result.weekExtraBecameComplete {
                let name = (try? client.extraDefs())?.first(where: { $0.id == id })?.name ?? id
                pendingWeeklyMoment = WeeklyMoment(
                    weekIndex: todayState?.weekIndex ?? 1,
                    extraName: name
                )
            }
            handle(result)
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Absorbs a LogResult produced by a direct client call (a view needing a
    /// facade parameter this model doesn't wrap, e.g. PhotoView's photoRef).
    /// Runs the exact same completion/refresh handling as internal intents.
    func noteExternalLog(_ result: LogResult) {
        handle(result)
    }

    // MARK: - Day lifecycle, undo, backfill

    /// Closes today's day ("the day ends when you tell it you're done") —
    /// later same-night logs roll to tomorrow. Wired to the day board's
    /// close-out button and the toolbar menu.
    func closeDay() {
        guard let date = todayState?.date else { return }
        do {
            _ = try client.closeDay(date: date)
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Revokes a specific event (undo primitive; projections skip revoked
    /// events). WorkoutView's swipe-to-undo lands here.
    func revoke(eventUuid: String) {
        do {
            try client.revokeEvent(eventUuid: eventUuid)
            if lastWaterEventUuid == eventUuid { lastWaterEventUuid = nil }
            if lastDietEventUuid == eventUuid { lastDietEventUuid = nil }
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Revokes exactly the last water event this model logged today, if any.
    /// (There is deliberately no kind-blind "undo last event" — it could nuke
    /// a workout/diet/photo log the user never meant to touch.)
    func undoLastWater() {
        guard let uuid = lastWaterEventUuid else { return }
        revoke(eventUuid: uuid)
    }

    /// Revokes exactly the last diet attest this model logged today, if any.
    func undoLastDiet() {
        guard let uuid = lastDietEventUuid else { return }
        revoke(eventUuid: uuid)
    }

    func backfill(days: [BackfilledDay]) {
        do {
            try client.backfillDays(days)
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    // MARK: - Plumbing

    private func run(_ intent: () throws -> LogResult) {
        do {
            handle(try intent())
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    private func handle(_ result: LogResult) {
        refresh()
        if result.dayBecameComplete {
            // The moment celebrates the day that flipped (result.dayState),
            // with the run as of the fresh post-log summary.
            pendingCompletionMoment = CompletionMoment(
                dayIndex: result.dayState.dayIndex,
                currentRun: summary?.currentRun ?? 1
            )
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Date plumbing (calendar-date arithmetic only; attribution stays in core)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func shift(_ date: DayDate, by days: Int) -> DayDate? {
        guard let base = dayFormatter.date(from: date),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return dayFormatter.string(from: shifted)
    }
}
