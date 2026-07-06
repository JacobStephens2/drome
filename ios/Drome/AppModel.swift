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

    // MARK: - Account & sync collaborators (Phase 2)

    /// The server JSON client and the Keychain-backed session store. Injected
    /// so tests/previews can swap them; defaults are production.
    let api: DromeAPI
    let keychain: KeychainSessionStore

    init(
        core: DromeCoreClient = MockDromeCore(),
        api: DromeAPI = DromeAPI(),
        keychain: KeychainSessionStore = KeychainSessionStore()
    ) {
        self.client = core
        self.api = api
        self.keychain = keychain
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

    /// Account/auth failures (sign-in, delete) surface HERE, not through the
    /// log-write "That didn't save" alert — its title asserts a log write
    /// failed, which is wrong for an auth/network problem. AccountView presents
    /// this with a fitting title.
    struct AccountAlert: Equatable {
        var title: String
        var message: String
    }
    private(set) var accountAlert: AccountAlert?

    func clearAccountAlert() {
        accountAlert = nil
    }

    /// One-shot: a sync adopted the account's active challenge and swapped this
    /// phone's day board. RootView surfaces it once (on the primary surface) so
    /// the board swap is never unexplained — the Account-screen banner alone is
    /// easy to miss. Cleared when the user dismisses the notice.
    var boardConflictNotice = false

    // MARK: - Account & sync (Phase 2 — opt-in; the app is fully usable signed out)

    /// Whether an account session exists (accounts are required only for sync
    /// and groups; all local features work signed out).
    private(set) var signedIn = false
    /// A non-sensitive display label for the signed-in account (email/name when
    /// Apple offered one at first sign-in, else a generic label). NOT a token.
    private(set) var accountLabel: String?
    /// The account's beta entitlement snapshot, fetched after sign-in.
    private(set) var entitlement: Entitlement?

    /// The sync driver, created on sign-in and torn down on sign-out. Views
    /// read status through the passthroughs below.
    private(set) var syncEngine: SyncEngine?

    /// The raw Sign-in-with-Apple nonce, stashed between the request (we hand
    /// Apple its SHA-256) and the completion (we send the raw to the server for
    /// replay binding). Never persisted.
    private var pendingAppleRawNonce: String?

    /// Legacy UserDefaults key: the display label (which could be a real email)
    /// used to be persisted here in cleartext. It now lives in the this-device
    /// Keychain item; this key is only purged on sign-out to remove any legacy
    /// value written by an earlier build.
    private static let accountLabelKey = "DromeAccountLabel"

    /// Which account owns the local data on this phone. Sign-out KEEPS all local
    /// data (challenge/events/photos), so on the next sign-in this binds that
    /// data to its account: signing into a DIFFERENT account must not upload one
    /// person's private challenge into another's account (see performSignIn).
    /// It's an opaque server account id, not PII. Cleared only when the local
    /// data is wiped (Start over) or its account is deleted.
    private static let localDataOwnerKey = "DromeLocalDataOwnerAccountId"

    private var localDataOwnerAccountId: Int64? {
        (UserDefaults.standard.object(forKey: Self.localDataOwnerKey) as? NSNumber)?.int64Value
    }

    private func setLocalDataOwner(_ accountId: Int64?) {
        if let accountId {
            UserDefaults.standard.set(NSNumber(value: accountId), forKey: Self.localDataOwnerKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.localDataOwnerKey)
        }
    }

    /// True when this phone holds an active challenge locally — the data a
    /// cross-account sign-in would otherwise upload to the wrong account.
    private func hasLocalChallengeData() -> Bool {
        ((try? client.activeChallenge()) ?? nil) != nil
    }

    /// Sync status surface (from the SyncEngine; quiet when signed out).
    var syncStatus: SyncStatus { syncEngine?.status ?? .idle }
    var lastSyncedAt: Date? { syncEngine?.lastSyncedAt }
    var pendingConflict: Bool { syncEngine?.pendingConflict ?? false }

    /// Restores a session persisted in the Keychain (called at launch). No-op
    /// when signed out. Kicks an initial sync and refreshes entitlement.
    func restoreAccountSession() {
        guard let session = keychain.load() else { return }
        accountLabel = session.label ?? "Signed in"
        signedIn = true
        // Back-fill the owner for a session signed in before this binding
        // existed, so its local data stays bound to this account.
        if localDataOwnerAccountId == nil {
            setLocalDataOwner(session.accountId)
        }
        makeSyncEngine(accountId: session.accountId)
        syncEngine?.syncNow()
        Task { await fetchEntitlement() }
    }

    /// Opportunistic sync poke (debounced; no-op when signed out). Wired to
    /// foreground and to every mutating intent below.
    func pokeSync() {
        syncEngine?.triggerSync()
    }

    // MARK: Sign in with Apple (UI-driven; AccountView owns the AS types)

    /// Generates a fresh replay nonce, stashes the raw value, and returns the
    /// SHA-256 the AccountView hands to Apple as `request.nonce`.
    func appleSignInRequestNonce() -> String {
        let nonce = AppleNonce.generate()
        pendingAppleRawNonce = nonce.raw
        return nonce.hashedForApple
    }

    /// Completes Sign in with Apple: the AccountView passes the identity token
    /// (and a display label when Apple offered one); we bind it to the stashed
    /// raw nonce server-side.
    func completeAppleSignIn(identityToken: String, label: String?) {
        guard let raw = pendingAppleRawNonce else {
            accountAlert = AccountAlert(
                title: "Couldn't sign in",
                message: "Sign in didn't complete. Please try again."
            )
            return
        }
        pendingAppleRawNonce = nil
        Task { await performSignIn(.apple(identityToken: identityToken, rawNonce: raw), label: label) }
    }

    /// Sign-in-with-Apple failed or was abandoned before an exchange.
    func appleSignInFailed(_ message: String?) {
        pendingAppleRawNonce = nil
        if let message {
            accountAlert = AccountAlert(title: "Couldn't sign in", message: message)
        }
    }

    #if DEBUG
    /// Local dev sign-in (server must run with `DROME_DEV_AUTH=1`). Debug only.
    func signInDev(key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            accountAlert = AccountAlert(title: "Couldn't sign in", message: "Enter a dev account key.")
            return
        }
        Task { await performSignIn(.dev(key: trimmed), label: "Dev: \(trimmed)") }
    }
    #endif

    private enum SignInMethod {
        case apple(identityToken: String, rawNonce: String)
        #if DEBUG
        case dev(key: String)
        #endif
    }

    private func performSignIn(_ method: SignInMethod, label: String?) async {
        do {
            let auth: AuthResponse
            switch method {
            case .apple(let token, let nonce):
                auth = try await api.authApple(identityToken: token, rawNonce: nonce)
            #if DEBUG
            case .dev(let key):
                auth = try await api.authDev(accountKey: key)
            #endif
            }
            // Cross-account guard: this phone keeps its local data across
            // sign-out, so attaching it to a DIFFERENT account would upload one
            // person's private challenge/events into another's account on the
            // first sync. If local data exists and is owned by another account,
            // refuse — the user must sign into the owning account, or Start
            // over to use a new one. (Nothing has been persisted or synced yet.)
            if hasLocalChallengeData(),
               let owner = localDataOwnerAccountId,
               owner != auth.accountId {
                accountAlert = AccountAlert(
                    title: "Can't sign in here",
                    message: "This phone already has challenge data linked to a "
                        + "different account. Sign in with that account, or use "
                        + "Start over in Settings to begin fresh on this one."
                )
                return
            }
            let resolvedLabel = label ?? "Signed in"
            // The display label lives in the this-device Keychain item, never
            // in cleartext UserDefaults (it can be a real email).
            try keychain.save(SessionTokens(
                accountId: auth.accountId,
                accessToken: auth.accessToken,
                refreshToken: auth.refreshToken,
                label: resolvedLabel
            ))
            setLocalDataOwner(auth.accountId)
            accountLabel = resolvedLabel
            signedIn = true
            makeSyncEngine(accountId: auth.accountId)
            syncEngine?.syncNow()
            await fetchEntitlement()
        } catch {
            accountAlert = AccountAlert(title: "Couldn't sign in", message: accountErrorText(error))
        }
    }

    // MARK: Sign out / delete account

    /// Signs out locally: clears the Keychain session and account state, tears
    /// down the sync engine. ALL local data (challenge, events, photos) stays.
    func signOut() {
        // Kill the engine FIRST so a lingering in-flight round-trip can never
        // start new work under a subsequently signed-in account's token.
        syncEngine?.invalidate()
        keychain.clear()
        syncEngine = nil
        signedIn = false
        accountLabel = nil
        entitlement = nil
        // The local-data owner is intentionally retained (sign-out keeps this
        // phone's data, which stays bound to its account).
        UserDefaults.standard.removeObject(forKey: Self.accountLabelKey) // purge any legacy PII
    }

    /// Deletes the account server-side (App Store requirement) then signs out
    /// locally. Confirm at the call site. Local data is untouched.
    func deleteAccount() {
        guard let session = keychain.load() else {
            finishAccountDeletion()
            return
        }
        Task {
            do {
                try await api.deleteAccount(accessToken: session.accessToken)
                finishAccountDeletion()
            } catch DromeAPIError.unauthorized {
                // Access and refresh share one 30-day expiry, so a 401 here
                // means the session is at/near expiry. Refresh once and retry
                // (mirroring the sync path) rather than stranding the user on a
                // dead session with no way to delete or re-authenticate.
                await deleteAccountAfterRefresh(session)
            } catch {
                accountAlert = AccountAlert(
                    title: "Couldn't delete account",
                    message: accountErrorText(error)
                )
            }
        }
    }

    private func deleteAccountAfterRefresh(_ session: SessionTokens) async {
        do {
            let refreshed = try await api.refresh(refreshToken: session.refreshToken)
            try? keychain.save(SessionTokens(
                accountId: refreshed.accountId,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                label: session.label
            ))
            try await api.deleteAccount(accessToken: refreshed.accessToken)
            finishAccountDeletion()
        } catch DromeAPIError.unauthorized {
            // Refresh also rejected: the session is truly dead and the account
            // was NOT deleted. Reconcile to signed-out (keeping the owner, since
            // the account still exists) so the user can sign in again to delete.
            signOut()
            accountAlert = AccountAlert(
                title: "Signed out",
                message: "Your session expired, so the account wasn't deleted. "
                    + "You've been signed out — sign in again to delete it."
            )
        } catch {
            accountAlert = AccountAlert(
                title: "Couldn't delete account",
                message: accountErrorText(error)
            )
        }
    }

    /// Completes an account deletion: signs out and releases the local-data
    /// owner binding. The server account is gone, so the local data is now
    /// unowned and may be adopted by the next sign-in (including a fresh
    /// re-auth of the same Apple ID, which mints a new account id).
    private func finishAccountDeletion() {
        signOut()
        setLocalDataOwner(nil)
    }

    // MARK: SyncEngine callbacks

    /// The engine forced a sign-out (refresh rejected). Local data untouched.
    func handleForcedSignOut(reason: String?) {
        signOut()
        if let reason { lastErrorMessage = reason }
    }

    /// A pull changed local state — re-project the UI and catch the widget up.
    func refreshAfterSync() {
        refresh()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A sync force-adopted the account's active challenge, swapping the board.
    /// Raise the one-shot notice RootView surfaces on the primary surface.
    func noteConflictAdopted() {
        boardConflictNotice = true
    }

    /// The engine hit a 402 (entitlement lapsed). Keep the cached snapshot
    /// honest with the paused sync status instead of showing a stale
    /// launch-time value in the Account "Plan" row.
    func markEntitlementLapsed() {
        entitlement = Entitlement(entitled: false, betaAllEntitled: false)
    }

    /// Re-reads the entitlement snapshot opportunistically (foreground while
    /// signed in), so the Plan row can't drift from the real server state
    /// between launches. No-op when signed out.
    func refreshEntitlementSnapshot() {
        guard signedIn else { return }
        Task { await fetchEntitlement() }
    }

    private func makeSyncEngine(accountId: Int64) {
        syncEngine = SyncEngine(
            client: client,
            api: api,
            keychain: keychain,
            context: String(accountId),
            appModel: self
        )
    }

    private func fetchEntitlement() async {
        guard let session = keychain.load() else { return }
        // Non-fatal: a failed read just leaves the snapshot nil (beta grants all).
        entitlement = try? await api.entitlement(accessToken: session.accessToken)
    }

    private func accountErrorText(_ error: Error) -> String {
        guard let apiError = error as? DromeAPIError else { return "\(error)" }
        switch apiError {
        case .offline:
            return "Couldn't reach the server. Check your connection and try again."
        case .unauthorized:
            return "That sign-in didn't go through. Please try again."
        case .notEntitled(let message):
            return message.isEmpty ? "Sync isn't available on this account right now." : message
        case .client(_, _, let message), .server(_, _, let message):
            return message.isEmpty ? "Something went wrong. Please try again." : message
        case .decoding, .unexpected:
            return "Something went wrong. Please try again."
        }
    }

    private var pendingWaterMl: Int64?

    /// Most recent today-attributed water event logged through this model.
    /// WaterView's "Undo last" revokes exactly this — never an arbitrary
    /// event of another kind. Cleared when that event is revoked.
    /// (Water is the one task without a `revokeTask` kind: it corrects via
    /// this targeted undo, the pour ledger, and drag-down adjustments.)
    private(set) var lastWaterEventUuid: String?

    /// Where each done weekly extra's live event sits (extra id → the date
    /// it was completed on), for the extra tile's toggle-off. An id appears
    /// exactly when `revokeTask(.extra(id:), date:)` would succeed there —
    /// extras satisfied only by a backfill flag never appear. Refreshed with
    /// the other projections.
    private(set) var weekExtraRevocableDates: [String: DayDate] = [:]

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
                weekExtraRevocableDates = [:]
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
            refreshWeekExtraRevocability()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Weekly-extra toggle-off support: per done extra, find the date its
    /// live event sits on. Best-effort like yesterday — a lookup failure just
    /// leaves that extra's toggle-off unavailable (renders plain done).
    private func refreshWeekExtraRevocability() {
        var dates: [String: DayDate] = [:]
        if let today = todayState {
            for extra in today.weekExtras where extra.doneThisWeek {
                guard let doneDate = extra.doneOnDate else { continue }
                let revocable = doneDate == today.date
                    ? today.day.revocable
                    : (try? client.dayState(date: doneDate))?.revocable
                if revocable?.extraIds.contains(extra.id) == true {
                    dates[extra.id] = doneDate
                }
            }
        }
        weekExtraRevocableDates = dates
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
        run { try client.logDietOk(effectiveDate: effectiveDate) }
    }

    /// "No Junk or Alcohol" attestation — the sixth core task, a peer of diet.
    func logNoJunkOk(effectiveDate: DayDate? = nil) {
        run { try client.logNoJunkOk(effectiveDate: effectiveDate) }
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
            pokeSync()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Revokes a specific event (undo primitive; projections skip revoked
    /// events). WorkoutView's swipe-to-undo and the workout-slot toggles
    /// land here; the attest-style tasks go through `revokeTask` instead.
    func revoke(eventUuid: String) {
        do {
            try client.revokeEvent(eventUuid: eventUuid)
            if lastWaterEventUuid == eventUuid { lastWaterEventUuid = nil }
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
            pokeSync()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Un-completes a task (diet / no-junk / photo / reading / weekly extra)
    /// on `date` — nil means today: the ONE toggle-off behind every attest
    /// surface. Attest kinds revoke ALL their live events on the date (the
    /// task genuinely flips off even when e.g. "mark taken" and an attach
    /// both logged photo events); reading peels its newest entry. Offer it
    /// only where `DayState.revocable` says it would succeed (backfill-flag
    /// days have nothing to revoke). Un-marking is a plain correction: the
    /// result's moment flags are hard-false, and the completion moment fires
    /// again, intentionally, on the log that re-completes the day. Revoked
    /// photos' JPEGs are deleted here (the one cleanup point), so no
    /// orphaned file can masquerade as that day's photo.
    func revokeTask(_ kind: RevocableTask, date: DayDate? = nil) {
        guard let target = date ?? todayState?.date else { return }
        do {
            let result = try client.revokeTask(kind, date: target)
            for ref in result.revokedPhotoRefs {
                PhotoStore.deleteFile(forRef: ref)
            }
            handle(result)
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

    func backfill(days: [BackfilledDay]) {
        do {
            try client.backfillDays(days)
            refresh()
            WidgetCenter.shared.reloadAllTimelines()
            pokeSync()
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    // MARK: - Reset (destructive; reached ONLY through ResetSheet's two acts)

    /// Wipes the app back to first launch: the core store (one transaction —
    /// a failure is a complete no-op and surfaces via `lastErrorMessage`),
    /// then every progress photo, the app's stored flags, and the widget.
    /// The DB wipe goes FIRST: if it fails, nothing else is touched. After
    /// `refresh()` the challenge is nil, so AppFlowView lands on onboarding —
    /// the caller must dismiss any presented sheet BEFORE invoking this so
    /// the full-screen swap doesn't strand one.
    ///
    /// Both failure messages are reset-specific, not the raw error: the user
    /// just confirmed "Delete everything", so the one thing the copy must
    /// answer is WHAT STATE THEIR DATA IS IN. A failed wipe = complete no-op
    /// (the core guarantees one transaction); surviving photo files after a
    /// committed wipe = the only partial state, and it is reported, never
    /// swallowed (`PhotoStore.deleteAllFiles` verifies).
    func resetApp() {
        do {
            try client.resetAllData()
        } catch {
            lastErrorMessage = "Couldn't reset. Nothing was deleted — your "
                + "challenge, history, and photos are all still here. "
                + "(\(exportErrorText(error)))"
            return
        }
        let photosDeleted = PhotoStore.deleteAllFiles()
        UserDefaults.standard.removeObject(forKey: "lastBackupAt")
        UserDefaults.standard.removeObject(forKey: "hasDragPoured")
        // Signed OUT: the wipe is permanent locally, so the fresh store is
        // unowned and any account may adopt it. Signed IN, do NOT release the
        // binding — a signed-in "Start over" re-mints the device id and the
        // next sync re-pulls this account's own history (reset-recovery), so
        // that recovered data is still owned by the signed-in account.
        if !signedIn {
            setLocalDataOwner(nil)
        }
        WidgetPaceCheck.clear()
        // Drop any queued one-shot UI moments — nothing pre-reset may fire
        // over onboarding.
        pendingCompletionMoment = nil
        pendingWeeklyMoment = nil
        cancelPendingWater()
        lastWaterEventUuid = nil
        refresh()
        if !photosDeleted {
            // Set AFTER refresh() (whose no-challenge branch clears errors).
            // RootView is gone once the challenge is nil, so AppFlowView
            // carries the alert that surfaces this over onboarding.
            lastErrorMessage = "Your challenge and history were erased, but "
                + "some progress photos couldn't be deleted. They may still "
                + "be in Drome's app storage on this phone; deleting the app "
                + "removes them."
        }
        WidgetCenter.shared.reloadAllTimelines()
        // A signed-in reset re-mints the device id in the core; the next sync
        // starts at cursor 0 and pulls the account's full history back down.
        pokeSync()
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
        // Opportunistic sync after any log/revoke-task (no-op when signed out).
        pokeSync()
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
