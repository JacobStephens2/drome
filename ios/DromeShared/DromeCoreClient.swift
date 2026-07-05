//
//  DromeCoreClient.swift
//  DromeShared
//
//  Facade protocol mirroring the drome-core public API (docs/ARCHITECTURE.md,
//  "Core public API"). Implementations stamp `LocalInstant.now` internally at
//  call time — views and AppModel NEVER pass "now". Dates are "YYYY-MM-DD"
//  strings (`DayDate`); `effectiveDate: nil` means "attribute by the core's
//  cutoff/closed-day rules", a non-nil value means retroactive logging.
//
//  Implementations: MockDromeCore (in-memory, previews + view fan-out stage)
//  and LiveDromeCore (bindings stage; wraps the UniFFI DromeStore).
//

import Foundation

protocol DromeCoreClient: AnyObject, Sendable {

    // MARK: Challenge lifecycle
    //
    // One active challenge at a time. `createChallenge` accepts an optional
    // past startDate (drives the backfill/onboarding flow).

    func activeChallenge() throws -> Challenge?
    @discardableResult
    func createChallenge(_ cfg: NewChallenge) throws -> Challenge

    // MARK: Config
    //
    // Container presets and extras are plain config (not events). Water-goal
    // changes ARE events: past days keep the goal they were lived under.
    // NOTE: `containerPresets()`/`extraDefs()` are Swift-facade getters not in
    // the pinned core API list — flagged for the bindings stage (see report).

    func containerPresets() throws -> [ContainerPreset]
    func updatePresets(_ presets: [ContainerPreset]) throws
    func extraDefs() throws -> [ExtraDef]
    func setExtraEnabled(id: String, enabled: Bool) throws
    func setCurrentBook(_ title: String) throws
    func setWaterGoal(ml: Int64) throws
    /// Display config; safe to edit mid-challenge (never rewrites past days).
    func setDietDescription(_ desc: String) throws
    /// Waking window (minutes after midnight); water pacing only.
    /// NOTE: day_cutoff_minutes deliberately has NO setter — changing it
    /// mid-challenge would re-attribute past events (docs/ARCHITECTURE.md).
    func setWakingWindow(startMinutes: UInt16, endMinutes: UInt16) throws

    // MARK: Logging intents
    //
    // Each returns a LogResult carrying the fresh DayState plus one-shot
    // `dayBecameComplete` / `weekExtraBecameComplete` flags and (for water)
    // an optional chug warning. Reading uses the challenge's current book
    // unless the caller passes a title.

    func logWater(ml: Int64, effectiveDate: DayDate?) throws -> LogResult
    /// Signed correction for over-recorded water. `ml` is NEGATIVE-ONLY
    /// (-10_000 ... -1); positive intake stays `logWater`. Throws
    /// `DromeError.invalidArgument` when |ml| exceeds the attributed day's
    /// current water total — clamp in the UI, but the core enforces it.
    /// Never returns a chug warning and never fires `dayBecameComplete`
    /// (it can only lower water). Revoking the correction's event restores
    /// the water it subtracted.
    func logWaterAdjustment(ml: Int64, effectiveDate: DayDate?) throws -> LogResult
    func logWorkout(durationMin: Int, outdoor: Bool, note: String?, effectiveDate: DayDate?) throws -> LogResult
    func logReading(bookTitle: String, pages: Int, effectiveDate: DayDate?) throws -> LogResult
    func logDietOk(effectiveDate: DayDate?) throws -> LogResult
    /// "No Junk or Alcohol" attestation — the sixth core task, a peer of
    /// diet. Required for `coreComplete` alongside the other five.
    func logNoJunkOk(effectiveDate: DayDate?) throws -> LogResult
    func logPhotoDone(photoRef: String?, effectiveDate: DayDate?) throws -> LogResult
    func logExtraDone(extraId: String, effectiveDate: DayDate?) throws -> LogResult

    // MARK: Day lifecycle, undo, backfill
    //
    // `closeDay` emits a day_closed event (later same-night logs roll to the
    // next day). `revokeEvent` is the undo primitive — projections skip
    // revoked events. `backfillDays` applies as a single transaction.

    @discardableResult
    func closeDay(date: DayDate) throws -> DayState
    func revokeEvent(eventUuid: String) throws
    func backfillDays(_ days: [BackfilledDay]) throws

    // MARK: Projections & queries
    //
    // All projections are computed against "now" captured inside the impl.

    func dayState(date: DayDate) throws -> DayState
    func today() throws -> TodayState
    func summary() throws -> ChallengeSummary
    func calendar(from: DayDate, to: DayDate) throws -> [DayBrief]
    func waterState() throws -> WaterState
    /// Every non-revoked water pour attributed to `date` (same attribution as
    /// the day projection, so entries sum to its `waterTotalMl`), ordered by
    /// `loggedAt` ascending. Drives the per-day pour log with per-entry
    /// removal (`revokeEvent`).
    func waterLog(date: DayDate) throws -> [WaterLogEntry]

    // MARK: Water safety
    //
    // `checkChug` evaluates the pending add WITHOUT logging. The UI must
    // surface the warning and only log after explicit confirmation.

    func checkChug(addMl: Int64) throws -> ChugCheck

    // MARK: Sharing & export
    //
    // Share cards carry the ruleset label and never photo refs. Exports are
    // the only data that leaves the device, and only user-initiated.

    func shareCard(date: DayDate) throws -> ShareCardData
    func exportJson() throws -> String
    func exportCsv() throws -> String

    // MARK: Restore

    /// Restores an `exportJson` snapshot. Only valid while no challenge is
    /// active in the store; throws `DromeError.challengeAlreadyActive`.
    func importJson(_ snapshot: String) throws
}

// MARK: - Convenience overloads (today-attributed logging)

extension DromeCoreClient {
    @discardableResult
    func logWater(ml: Int64) throws -> LogResult {
        try logWater(ml: ml, effectiveDate: nil)
    }

    @discardableResult
    func logWaterAdjustment(ml: Int64) throws -> LogResult {
        try logWaterAdjustment(ml: ml, effectiveDate: nil)
    }

    @discardableResult
    func logNoJunkOk() throws -> LogResult {
        try logNoJunkOk(effectiveDate: nil)
    }

    @discardableResult
    func logWorkout(durationMin: Int, outdoor: Bool, note: String? = nil) throws -> LogResult {
        try logWorkout(durationMin: durationMin, outdoor: outdoor, note: note, effectiveDate: nil)
    }

    @discardableResult
    func logReading(bookTitle: String, pages: Int) throws -> LogResult {
        try logReading(bookTitle: bookTitle, pages: pages, effectiveDate: nil)
    }

    @discardableResult
    func logDietOk() throws -> LogResult {
        try logDietOk(effectiveDate: nil)
    }

    @discardableResult
    func logPhotoDone(photoRef: String? = nil) throws -> LogResult {
        try logPhotoDone(photoRef: photoRef, effectiveDate: nil)
    }

    @discardableResult
    func logExtraDone(extraId: String) throws -> LogResult {
        try logExtraDone(extraId: extraId, effectiveDate: nil)
    }
}
