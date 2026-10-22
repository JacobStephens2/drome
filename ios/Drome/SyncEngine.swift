//
//  SyncEngine.swift
//  Drome
//
//  Drives sync round-trips against the core facade (docs/PHASE2.md "Reset
//  epoch"). The engine only moves JSON over the network and stamps status.
//  Prepare, the tail, and the follow-up predicate live in the Rust core.
//
//  Round-trip control flow:
//    1. prepareSyncRound reads the epoch, device id, cursor, pending events,
//       and config in one store transaction.
//    2. POST /v1/sync. This is the only await between prepare and apply, so a
//       "Start over" can only interleave here.
//    3. applySyncResponse commits the tail, or writes nothing if the epoch
//       moved. The store checks the epoch before it validates the payload.
//    4. syncFollowUp is the only continuation decision. True schedules another
//       debounced round. Adopting a winner does not, by itself.
//    5. On 401, refresh once and retry; if refresh is also rejected, sign out
//       locally (local data untouched) and surface it.
//
//  Scheduling is opportunistic: a debounced trigger after logs and on
//  foreground, serialized so two round-trips can never overlap, and never
//  blocking the UI. There is no numeric cap; the debounce yields the CPU.
//

import Foundation

/// What the account/sync surface shows (docs/PHASE2.md: quiet, honest).
enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case error(String)
}

@MainActor
@Observable
final class SyncEngine {

    // MARK: Observable status (read by AccountView)

    private(set) var status: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    /// This phone's active challenge was archived in favour of the account's
    /// existing one. Surfaced as an honest banner; the user can dismiss it.
    var pendingConflict = false

    // MARK: Collaborators

    private let client: DromeCoreClient
    private let api: DromeAPI
    private let keychain: KeychainSessionStore
    /// The sync watermark context — the account id string. Push/pull cursors
    /// are keyed by it, so switching accounts never crosses cursors.
    private let context: String
    private weak var appModel: AppModel?

    // MARK: Scheduling state (all main-actor, so no locks needed)

    private var isRunning = false
    private var queued = false
    private var debounceTask: Task<Void, Never>?
    /// Set once the engine is torn down (sign-out / delete). A dead engine
    /// starts no new work, so a lingering in-flight round-trip can never push
    /// this account's watermark under a newly signed-in account's token.
    private var dead = false
    /// Rotated tokens kept in memory when a post-refresh Keychain write failed.
    /// The server already invalidated the OLD refresh token, so the Keychain
    /// holds dead credentials; preferring these valid tokens avoids escalating
    /// a healthy account to a forced sign-out on the next cycle.
    private var sessionOverride: SessionTokens?

    /// Cap on events pushed per round-trip; steady state is far under this.
    private let pushBatchLimit: UInt32 = 500
    private let debounceNanos: UInt64 = 400_000_000 // 0.4s

    init(
        client: DromeCoreClient,
        api: DromeAPI,
        keychain: KeychainSessionStore,
        context: String,
        appModel: AppModel
    ) {
        self.client = client
        self.api = api
        self.keychain = keychain
        self.context = context
        self.appModel = appModel
    }

    // MARK: - Triggers

    /// Debounced opportunistic trigger (after a log/revoke/backfill/reset, or on
    /// foreground). Coalesces a burst of edits into one round-trip.
    func triggerSync() {
        guard !dead else { return }
        let delay = debounceNanos
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.runSerialized()
        }
    }

    /// Immediate trigger (sign-in / launch), skipping the debounce.
    func syncNow() {
        guard !dead else { return }
        debounceTask?.cancel()
        runSerialized()
    }

    /// Tears the engine down: cancels the debounce and marks it dead so no new
    /// round-trip (nor a queued re-run) can start. Call from AppModel BEFORE
    /// dropping the reference on sign-out / delete, so an in-flight round-trip
    /// can finish for its own account but never spawn work under the next one.
    func invalidate() {
        dead = true
        queued = false
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Serializes round-trips: if one is running, remember to run again after,
    /// so an edit during a sync never gets stranded and two never overlap.
    private func runSerialized() {
        guard !dead else { return }
        if isRunning {
            queued = true
            return
        }
        isRunning = true
        // Strong self on purpose: the round-trip must finish even if AppModel
        // drops its reference to this engine mid-flight (e.g. forced sign-out).
        Task {
            await self.performSyncLocked()
            self.isRunning = false
            if self.queued && !self.dead {
                self.queued = false
                self.runSerialized()
            }
        }
    }

    // MARK: - One serialized sync

    private func performSyncLocked() async {
        if dead { return }
        guard let session = sessionOverride ?? keychain.load() else {
            // Signed out from under us; nothing to sync.
            appModel?.handleForcedSignOut(reason: nil)
            return
        }
        // Token and watermark context MUST agree. This engine's push/pull
        // cursors are keyed by `context` (an account id); syncing them under a
        // different account's bearer token would cross accounts. If the loaded
        // session is for another account, this engine is stale (a live engine
        // for the right account exists) — do nothing.
        guard String(session.accountId) == context else { return }
        status = .syncing
        do {
            let outcome = try await roundTrip(accessToken: session.accessToken)
            settle(outcome)
        } catch DromeAPIError.unauthorized {
            await refreshThenRetry(session)
        } catch let error as DromeAPIError {
            if case .notEntitled = error { appModel?.markEntitlementLapsed() }
            status = .error(error.userMessage)
        } catch {
            // Core-side failures (validation, storage) land here too.
            status = .error("Sync failed. It'll try again.")
        }
    }

    /// 401 recovery: rotate the session once, then retry the round-trip once.
    /// A second 401 (or a rejected refresh) means the session is truly dead —
    /// sign out locally, keeping all local data, and surface it.
    private func refreshThenRetry(_ session: SessionTokens) async {
        do {
            let refreshed = try await api.refresh(refreshToken: session.refreshToken)
            let rotated = SessionTokens(
                accountId: refreshed.accountId,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                label: session.label
            )
            do {
                try keychain.save(rotated)
                sessionOverride = nil
            } catch {
                // The refresh SUCCEEDED (so the server already invalidated the
                // old refresh token), but persisting the rotated tokens failed.
                // Keep the valid tokens in memory and prefer them next cycle;
                // otherwise the next sync would 401 on the now-dead Keychain
                // tokens and escalate a healthy account to a forced sign-out.
                sessionOverride = rotated
            }
            let outcome = try await roundTrip(accessToken: rotated.accessToken)
            settle(outcome)
        } catch DromeAPIError.unauthorized {
            appModel?.handleForcedSignOut(
                reason: "You've been signed out. Sign in again to resume syncing — "
                    + "your challenge and history on this phone are untouched."
            )
        } catch let error as DromeAPIError {
            if case .notEntitled = error { appModel?.markEntitlementLapsed() }
            status = .error(error.userMessage)
        } catch {
            status = .error("Sync failed. It'll try again.")
        }
    }

    // MARK: - The round-trip (reset-epoch invariant)

    private struct RoundTripOutcome {
        var outcome: SyncOutcome
        var conflict: Bool
        /// The core predicate. The only reason to schedule another round.
        var followUp: Bool
    }

    private func roundTrip(accessToken: String) async throws -> RoundTripOutcome {
        let prepared = try client.prepareSyncRound(context: context, limit: pushBatchLimit)

        // The only await between prepare and apply, so a "Start over" can
        // only interleave here. Apply then no-ops the whole tail.
        let response = try await api.sync(
            SyncRequest(
                deviceId: prepared.deviceId,
                lastServerSeq: prepared.lastServerSeq,
                events: prepared.events,
                configJSON: prepared.configJSON
            ),
            accessToken: accessToken
        )

        let applied = try client.applySyncResponse(
            context: context,
            expectedResetEpoch: prepared.resetEpoch,
            ackedUuids: response.ackedUuids,
            configJSON: response.configJSON,
            winnerChallengeId: response.activeChallengeConflict?.winnerChallengeId,
            events: response.events,
            newLastServerSeq: response.newLastServerSeq
        )
        let followUp = client.syncFollowUp(
            pushedCount: UInt32(prepared.events.count),
            pushLimit: pushBatchLimit,
            more: response.moreToPull,
            outcome: applied.outcome
        )
        return RoundTripOutcome(
            outcome: applied.outcome,
            conflict: response.activeChallengeConflict != nil,
            followUp: followUp
        )
    }

    private func settle(_ outcome: RoundTripOutcome) {
        switch outcome.outcome {
        case .staleReset:
            // Nothing was written. A fresh prepare recovers at cursor 0.
            status = .idle
        case .applied:
            // Refresh even when `inserted` is 0. A config-only pull changes
            // local state without storing a new event.
            lastSyncedAt = Date()
            status = .idle
            if outcome.conflict {
                pendingConflict = true
                // Surface the board swap where it's visible, not only in the
                // Account screen banner. Adoption itself does not schedule
                // another round; the winner and its events landed together.
                appModel?.noteConflictAdopted()
            }
            // Re-project on EVERY applied round-trip: a config-only pull (a
            // synced challenge/book/extras/presets change carries no events, so
            // inserted == 0) must not stay invisible — otherwise a fresh device
            // can sit on onboarding until an unrelated refresh, and a running
            // board can show stale config after another device edits it.
            appModel?.refreshAfterSync()
        }
        if outcome.followUp {
            triggerSync()
        }
    }
}
