//
//  AppModel.swift
//  Drome
//
//  App-wide observable state. Owns the DromeCoreClient facade, caches the
//  projections views render from, and exposes intent methods. Views never
//  talk to the core directly and never pass "now" — implementations stamp
//  time internally (docs/ARCHITECTURE.md, "Swift layer contracts").
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {

    // MARK: - Core client

    // SWAP POINT: when the bindings stage lands, replace the default with
    // LiveDromeCore(dbPath: <App Group container>/drome.sqlite). Nothing else
    // in the app layer should need to change.
    private let core: DromeCoreClient

    init(core: DromeCoreClient = MockDromeCore()) {
        self.core = core
    }

    // MARK: - Cached projections

    private(set) var challenge: Challenge?
    private(set) var todayState: TodayState?
    private(set) var summary: ChallengeSummary?
    private(set) var waterState: WaterState?
    private(set) var presets: [ContainerPreset] = []

    /// Set once when a log flips the day to complete; the UI shows the
    /// completion moment and clears this flag afterwards.
    var pendingCompletionMoment = false

    /// Set when a water log would breach the anti-chug guard. The UI must
    /// surface this and only log after `confirmPendingWater()`.
    var pendingChugWarning: ChugCheck?

    /// Most recent user-visible error, if any (mock rarely throws).
    private(set) var lastErrorMessage: String?

    private var pendingWaterMl: Int64?
    private var lastEventUuid: String?

    // MARK: - Refresh

    func refresh() {
        do {
            challenge = try core.activeChallenge()
            todayState = try core.today()
            summary = try core.summary()
            waterState = try core.waterState()
            presets = try core.containerPresets()
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
            let check = try core.checkChug(addMl: ml)
            if check.shouldWarn {
                pendingWaterMl = ml
                pendingChugWarning = check
                return check
            }
            handle(try core.logWater(ml: ml, effectiveDate: nil))
            return nil
        } catch {
            lastErrorMessage = "\(error)"
            return nil
        }
    }

    /// Explicit user confirmation of a warned water log. Never celebrated.
    func confirmPendingWater() {
        guard let ml = pendingWaterMl else { return }
        pendingWaterMl = nil
        pendingChugWarning = nil
        do {
            handle(try core.logWater(ml: ml, effectiveDate: nil))
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

    // MARK: - Other logging intents

    func logWorkout(durationMin: Int, outdoor: Bool, note: String? = nil) {
        run { try core.logWorkout(durationMin: durationMin, outdoor: outdoor, note: note, effectiveDate: nil) }
    }

    /// Pages against the challenge's current book.
    func logReading(pages: Int) {
        let book = challenge?.currentBook ?? ""
        run { try core.logReading(bookTitle: book, pages: pages, effectiveDate: nil) }
    }

    func logDietOk() {
        run { try core.logDietOk(effectiveDate: nil) }
    }

    func logPhotoDone() {
        run { try core.logPhotoDone(photoRef: nil, effectiveDate: nil) }
    }

    func logExtraDone(id: String) {
        run { try core.logExtraDone(extraId: id, effectiveDate: nil) }
    }

    // MARK: - Day lifecycle, undo, backfill

    func closeDay() {
        guard let date = todayState?.date else { return }
        do {
            _ = try core.closeDay(date: date)
            refresh()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Revokes the most recent event logged through this model, if any.
    func undoLast() {
        guard let uuid = lastEventUuid else { return }
        do {
            try core.revokeEvent(eventUuid: uuid)
            lastEventUuid = nil
            refresh()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    func backfill(days: [BackfilledDay]) {
        do {
            try core.backfillDays(days)
            refresh()
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
        if result.dayBecameComplete {
            pendingCompletionMoment = true
        }
        refresh()
    }
}
