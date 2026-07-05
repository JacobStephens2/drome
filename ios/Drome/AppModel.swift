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

    /// Most recent user-visible error, if any.
    private(set) var lastErrorMessage: String?

    private var pendingWaterMl: Int64?
    private var lastEventUuid: String?

    // MARK: - Refresh

    func refresh() {
        do {
            challenge = try client.activeChallenge()
            guard challenge != nil else {
                todayState = nil
                summary = nil
                waterState = nil
                presets = []
                lastErrorMessage = nil
                return
            }
            todayState = try client.today()
            summary = try client.summary()
            waterState = try client.waterState()
            presets = try client.containerPresets()
            lastErrorMessage = nil
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
            handle(try client.logWater(ml: ml, effectiveDate: nil))
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
            handle(try client.logWater(ml: ml, effectiveDate: nil))
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

    /// Retroactive water log ("log for yesterday"). Skips the anti-chug
    /// pre-check on purpose: the water was drunk on the effective day, not in
    /// the trailing hour, so a warning here would be dishonest.
    func logWater(ml: Int64, effectiveDate: DayDate?) {
        guard let effectiveDate else {
            checkThenLogWater(ml: ml)
            return
        }
        run { try client.logWater(ml: ml, effectiveDate: effectiveDate) }
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
        run { try client.logDietOk(effectiveDate: effectiveDate) }
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
            if lastEventUuid == eventUuid { lastEventUuid = nil }
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Revokes the most recent event logged through this model, if any.
    func undoLast() {
        guard let uuid = lastEventUuid else { return }
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
        lastEventUuid = result.eventUuid
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
}
