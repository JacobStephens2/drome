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
    /// Un-completes `kind` on `date` (same attribution as `dayState`). The
    /// attest kinds (.diet/.noJunk/.photo/.extra) are idempotent, not
    /// additive: ALL their live events attributed to the date are revoked,
    /// so one call always flips the task to not-done; `.reading` is additive
    /// and peels only the NEWEST entry and its pages. `.extra` matches its
    /// id. `DayState.revocable` reports, per task, whether this would
    /// succeed. The returned LogResult carries the fresh day state;
    /// `dayBecameComplete` / `weekExtraBecameComplete` are always false for
    /// a revoke (the moments then fire again, intentionally, on the log that
    /// re-completes), and `revokedPhotoRefs` carries every revoked photo's
    /// ref so the app layer can delete the orphaned files. Throws
    /// `DromeError.taskNotRevocable` when nothing satisfies the task on that
    /// date (e.g. done only via a backfill flag, or nothing logged).
    @discardableResult
    func revokeTask(_ kind: RevocableTask, date: DayDate) throws -> LogResult
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

    // MARK: Reset (destructive — the Settings "Start over" flow ONLY)

    /// Wipes the entire store — challenge, events, presets, extra defs —
    /// back to its never-used state, in one core transaction (a failure is
    /// a complete no-op; the events append-only guard is recreated intact).
    /// The app layer owns the rest of a reset: photo files, @AppStorage
    /// flags, widget state. Call only from `AppModel.resetApp()`.
    func resetAllData() throws

    // MARK: Sync (Phase 2 — plumbing for the SyncEngine, NOT view surface)
    //
    // Sync is idempotent event exchange (docs/PHASE2.md). `context` is the
    // opaque account identifier the watermark state is keyed by (independent
    // push/pull cursors per account). These are consumed by the iOS
    // SyncEngine built in the next stage; views never call them.

    /// This store's stable device id (config-LWW tiebreak; sent with sync
    /// requests so the server can label event provenance).
    func deviceId() throws -> String
    /// This store's current reset generation (docs/PHASE2.md, sync/reset epoch
    /// invariant). The SyncEngine reads this ONCE at the start of a round-trip
    /// and threads it into every cursor-or-state-mutating tail write below; a
    /// local "Start over" (`resetAllData`) between the capture and the tail
    /// bumps the epoch, so those writes NO-OP (`.staleReset`) instead of
    /// resurrecting the pre-reset pull cursor — the fix for the reset/sync
    /// data-loss race. A never-reset store reads 0.
    func currentResetEpoch() throws -> Int64
    /// Local events past `context`'s synced-through watermark (oldest first,
    /// capped at `limit`), serialized for the wire. Remote-origin events are
    /// never returned; `photo_done` payloads are stripped of `photoRef`.
    func pendingEvents(context: String, limit: UInt32) throws -> [WireEvent]
    /// Advances `context`'s push watermark past every acked uuid.
    /// `expectedResetEpoch` is the epoch captured at the round-trip's start;
    /// returns `.staleReset` (a NO-OP, not an error) when a reset ran since.
    @discardableResult
    func ackPushed(context: String, uuids: [String], expectedResetEpoch: Int64) throws
        -> SyncOutcome
    /// Idempotently upserts pulled events (uuids already present, including
    /// revoked, are skipped; inserted rows are marked remote-origin so they
    /// are never pushed back). Returns the number actually inserted.
    @discardableResult
    func applyRemoteEvents(_ events: [WireEvent]) throws -> UInt32
    /// This store's config block (challenge settings, presets, extras) with
    /// per-slot LWW stamps, as JSON — the `config` half of a sync round-trip.
    func exportConfigState() throws -> String
    /// Merges a remote config block (JSON from `exportConfigState`) per-slot
    /// last-writer-wins on `(updatedAt, deviceId)`. `expectedResetEpoch` is the
    /// epoch captured at the round-trip's start; returns `.staleReset` (a
    /// NO-OP) when a reset ran since, rather than re-materializing wiped config.
    @discardableResult
    func applyRemoteConfig(_ blockJson: String, expectedResetEpoch: Int64) throws -> SyncOutcome
    /// Adopts the server-declared winner of a one-active-challenge conflict.
    /// Call this INSTEAD of `applyRemoteConfig` when a sync response carries an
    /// `active_challenge_conflict`: `blockJson` is that response's `config` (the
    /// winner's slots) and `winnerChallengeId` its `winner_challenge_id`. Unlike
    /// the LWW merge, it force-adopts the winner even when this device's local
    /// challenge stamp is newer, and archives the loser locally — without it a
    /// device that lost the race keeps its own active challenge forever (a
    /// split-brain the server cannot resolve). Idempotent.
    func adoptActiveChallenge(blockJson: String, winnerChallengeId: String) throws
    /// `context`'s pull cursor (highest applied `server_seq`; 0 if never
    /// pulled).
    func lastServerSeq(context: String) throws -> Int64
    /// Advances `context`'s pull cursor after applying a pull batch.
    /// `expectedResetEpoch` is the epoch captured at the round-trip's start;
    /// returns `.staleReset` (a NO-OP) when a reset ran since.
    @discardableResult
    func setLastServerSeq(context: String, seq: Int64, expectedResetEpoch: Int64) throws
        -> SyncOutcome
    /// Applies a pulled batch AND advances `context`'s pull cursor in ONE core
    /// transaction. Prefer this over separate `applyRemoteEvents` +
    /// `setLastServerSeq`: bundling both writes means the cursor can never
    /// outrun the durably-applied events, so a crash between the two can't
    /// silently drop events. `expectedResetEpoch` is the epoch captured at the
    /// round-trip's start; when a reset ran since, the WHOLE batch is dropped
    /// and the result is `{ .staleReset, inserted: 0 }`. Otherwise the result
    /// is `{ .applied, inserted: <count> }`.
    @discardableResult
    func applyPullBatch(
        context: String,
        events: [WireEvent],
        newLastServerSeq: Int64,
        expectedResetEpoch: Int64
    ) throws -> PullResult
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
