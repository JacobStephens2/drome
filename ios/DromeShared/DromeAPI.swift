//
//  DromeAPI.swift
//  DromeShared
//
//  URLSession JSON client for the Drome server (docs/PHASE2.md "Endpoints v1").
//  Pure transport: it moves JSON over HTTP, stamps the bearer token, and maps
//  outcomes to a typed error. It NEVER touches the Rust core, the Keychain, or
//  the UI — the app-only SyncEngine composes it with the core facade.
//
//  Codable request/response types mirror the server's JSON EXACTLY (snake_case
//  via explicit CodingKeys — deliberately no key-conversion strategy, so the
//  opaque `config` block round-trips verbatim). The core owns the config
//  schema, so it crosses this layer as raw JSON (`RawJSON`), never re-typed.
//
//  Lives in DromeShared (Foundation-only) so a future widget could reuse the
//  session types; the sign-in UI and Keychain stay app-only.
//

import Foundation

// MARK: - Base URL configuration

/// Where the client talks to. DEBUG defaults to the local dev server; Release
/// to production. A single UserDefaults override lets a DEBUG build point
/// elsewhere (e.g. a LAN IP for on-device testing) without a recompile.
enum DromeAPIConfig {
    /// Set a full base URL string here to override the compiled default.
    /// DEBUG-only: honoring an unvalidated defaults key in Release would let
    /// anything that can write standard defaults redirect the bearer token to
    /// an arbitrary host, so Release is pinned to `defaultBaseURL`.
    static let baseURLOverrideKey = "DromeServerBaseURL"

    static var defaultBaseURL: URL {
        #if DEBUG
        return URL(string: "http://localhost:8080")!
        #else
        return URL(string: "https://drome.day")!
        #endif
    }

    static var baseURL: URL {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: baseURLOverrideKey),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: raw) {
            return url
        }
        #endif
        return defaultBaseURL
    }
}

// MARK: - Errors

/// Every failure the client can surface, typed so the SyncEngine can react:
/// `unauthorized` triggers a refresh; `offline` is transient (retry later);
/// the rest are surfaced honestly.
enum DromeAPIError: Error, Equatable {
    /// Transport failure — offline, DNS, timeout, TLS. Transient; retry later.
    case offline(String)
    /// HTTP 401 — the session token was rejected (refresh, then retry once).
    case unauthorized(code: String, message: String)
    /// HTTP 402 — no active entitlement (sync/groups paused; never the local app).
    case notEntitled(message: String)
    /// Other 4xx — a client-side problem (bad request, rate limited, 404…).
    case client(status: Int, code: String, message: String)
    /// 5xx — a server-side failure.
    case server(status: Int, code: String, message: String)
    /// A 2xx body that couldn't be decoded into the expected shape.
    case decoding(String)
    /// Anything unexpected (non-HTTP response, malformed config…).
    case unexpected(String)

    /// A short, non-shaming line for the sync status surface.
    var userMessage: String {
        switch self {
        case .offline:
            return "Couldn't reach the server. It'll try again."
        case .unauthorized:
            return "Your session needs a refresh."
        case .notEntitled:
            return "Sync is paused. Your data on this phone is untouched."
        case .client(_, _, let message), .server(_, _, let message):
            return message.isEmpty ? "Sync failed. It'll try again." : message
        case .decoding, .unexpected:
            return "Sync failed. It'll try again."
        }
    }
}

// MARK: - SyncEngine-facing request / response

/// One sync round-trip's payload, in core-facade terms: the pending events and
/// the config block as its raw JSON (from `exportConfigState()`), so the engine
/// never re-types what the core owns.
struct SyncRequest {
    var deviceId: String
    var lastServerSeq: Int64
    var events: [WireEvent]
    /// The config block JSON from `DromeCoreClient.exportConfigState()`.
    var configJSON: String
}

struct SyncResponse {
    var ackedUuids: [String]
    var events: [WireEvent]
    var newLastServerSeq: Int64
    /// True when the server capped this pull and more events remain past
    /// `newLastServerSeq`; the engine re-triggers a round-trip to drain them.
    var moreToPull: Bool
    /// The account's canonical config JSON — feed to `applyRemoteConfig` (or
    /// `adoptActiveChallenge` when `activeChallengeConflict` is set).
    var configJSON: String
    var activeChallengeConflict: ActiveChallengeConflict?
}

/// This device's active challenge lost the one-active-challenge race; its
/// challenge was archived and the winner is in `SyncResponse.config`.
struct ActiveChallengeConflict: Equatable {
    var archivedChallengeId: String
    var winnerChallengeId: String
}

/// A minted session (identical shape from Apple, dev, and refresh).
struct AuthResponse: Sendable, Equatable {
    var accountId: Int64
    var accessToken: String
    var refreshToken: String
    var expiresAtEpoch: Int64
}

/// The account's beta entitlement snapshot.
struct Entitlement: Sendable, Equatable {
    var entitled: Bool
    var betaAllEntitled: Bool
}

// MARK: - Group DTOs (docs/PHASE2.md "Groups"; decode the server JSON EXACTLY)
//
// PRIVACY: these types carry ONLY what the server chose to expose — each
// member's display name, day index, current run, and today's per-task
// done/not booleans, plus a single done/not for this week's extra. There is
// deliberately no field for a photo, a note, the diet text, a water amount, or
// the weekly extra's name/id: the data simply isn't on the wire, so the UI
// cannot render more than the contract allows.

/// A group reference returned by create/join (`{id, name, invite_code}`).
struct GroupRef: Decodable, Sendable, Equatable {
    var id: String
    var name: String
    var inviteCode: String
    enum CodingKeys: String, CodingKey {
        case id, name
        case inviteCode = "invite_code"
    }
}

/// One row of `GET /v1/groups` — a group I belong to, with my per-group
/// display name (nullable server-side) and the current member count.
struct GroupSummary: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var inviteCode: String
    var myDisplayName: String?
    var memberCount: Int
    enum CodingKeys: String, CodingKey {
        case id, name
        case inviteCode = "invite_code"
        case myDisplayName = "my_display_name"
        case memberCount = "member_count"
    }
}

/// The seven core-task done/not booleans for a member's "today" — field-for-
/// field the server's `tasks` object. No amounts, ever.
struct GroupMemberTasks: Decodable, Sendable, Equatable {
    var water: Bool
    var outdoorWorkout: Bool
    var secondWorkout: Bool
    var reading: Bool
    var diet: Bool
    var noJunk: Bool
    var photo: Bool
    enum CodingKeys: String, CodingKey {
        case water
        case outdoorWorkout = "outdoor_workout"
        case secondWorkout = "second_workout"
        case reading, diet
        case noJunk = "no_junk"
        case photo
    }
}

/// A member's privacy-safe day-state, from `GET /v1/groups/:id` `members[]`.
/// The day fields (`dayIndex`, `currentRun`, `tasks`, `weeklyExtraDone`) are
/// present ONLY when `isActive`; an inactive member (no active challenge
/// synced) omits them, so they decode to nil.
///
/// PRIVACY: the member identifier on the wire is `handle` — an OPAQUE, per-group
/// value. The global account id is deliberately NOT exposed, so the same person
/// carries a different handle in each group and cannot be correlated across
/// them. `isSelf` (server-computed) marks "you" without needing that global id;
/// nudges target `handle`.
struct GroupMember: Decodable, Sendable, Equatable, Identifiable {
    var handle: String
    var displayName: String
    var isSelf: Bool
    var isActive: Bool
    var dayIndex: Int?
    var currentRun: Int?
    var tasks: GroupMemberTasks?
    var weeklyExtraDone: Bool?

    var id: String { handle }

    enum CodingKeys: String, CodingKey {
        case handle = "member_handle"
        case displayName = "display_name"
        case isSelf = "is_self"
        case isActive = "is_active"
        case dayIndex = "day_index"
        case currentRun = "current_run"
        case tasks
        case weeklyExtraDone = "weekly_extra_done"
    }
}

/// Full group detail from `GET /v1/groups/:id`.
struct GroupDetail: Decodable, Sendable, Equatable {
    var id: String
    var name: String
    var inviteCode: String
    var members: [GroupMember]
    enum CodingKeys: String, CodingKey {
        case id, name
        case inviteCode = "invite_code"
        case members
    }
}

/// One pending in-app nudge from `GET /v1/nudges` — content-free by design:
/// the sender's per-group display name and the group's name, nothing else.
struct PendingNudge: Decodable, Sendable, Equatable {
    var fromDisplayName: String
    var groupName: String
    enum CodingKeys: String, CodingKey {
        case fromDisplayName = "from_display_name"
        case groupName = "group_name"
    }
}

// MARK: - Client

/// Stateless w.r.t. credentials: authed calls take the access token explicitly,
/// so there is no shared mutable token to race. Safe to call from any actor.
final class DromeAPI {
    private let baseURL: URL
    private let session: URLSession
    // No key strategy: every wire type spells its snake_case keys out, and the
    // config block passes through as raw JSON untouched by any transform.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL = DromeAPIConfig.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Auth

    /// `POST /v1/auth/apple` — exchange an Apple identity token (bound to the
    /// raw replay nonce) for a session.
    func authApple(identityToken: String, rawNonce: String) async throws -> AuthResponse {
        let body = try encoder.encode(AppleAuthBody(identityToken: identityToken, nonce: rawNonce))
        return try await postAuth(path: "v1/auth/apple", body: body)
    }

    /// `POST /v1/auth/email/request` — email a six-digit code. Returns on 2xx
    /// (204 No Content, no body); the code is redeemed via `authEmailVerify`.
    func authEmailRequest(email: String) async throws {
        let body = try encoder.encode(EmailRequestBody(email: email))
        let (data, http) = try await send(
            request("v1/auth/email/request", method: "POST", accessToken: nil, body: body)
        )
        try ensureOK(data, http)
    }

    /// `POST /v1/auth/email/verify` — exchange the emailed code for a session.
    func authEmailVerify(email: String, code: String) async throws -> AuthResponse {
        let body = try encoder.encode(EmailVerifyBody(email: email, code: code))
        return try await postAuth(path: "v1/auth/email/verify", body: body)
    }

    #if DEBUG
    /// `POST /v1/auth/dev` — LOCAL DEV ONLY. Mints a session for a synthetic
    /// account keyed by `accountKey` (server must run with `DROME_DEV_AUTH=1`,
    /// else this 404s). Compiled out of Release entirely.
    func authDev(accountKey: String) async throws -> AuthResponse {
        let body = try encoder.encode(DevAuthBody(accountKey: accountKey))
        return try await postAuth(path: "v1/auth/dev", body: body)
    }
    #endif

    /// `POST /v1/auth/refresh` — rotate both tokens (only while unexpired).
    func refresh(refreshToken: String) async throws -> AuthResponse {
        let body = try encoder.encode(RefreshBody(refreshToken: refreshToken))
        return try await postAuth(path: "v1/auth/refresh", body: body)
    }

    private func postAuth(path: String, body: Data) async throws -> AuthResponse {
        let (data, http) = try await send(request(path, method: "POST", accessToken: nil, body: body))
        try ensureOK(data, http)
        return try decode(AuthResponseBody.self, data).toModel()
    }

    // MARK: Sync

    /// `POST /v1/sync` — push pending events + config, pull newer events.
    func sync(_ req: SyncRequest, accessToken: String) async throws -> SyncResponse {
        let body = try encoder.encode(SyncRequestBody(
            deviceId: req.deviceId,
            lastServerSeq: req.lastServerSeq,
            events: req.events.map(APIWireEvent.init),
            config: try RawJSON(jsonText: req.configJSON)
        ))
        let (data, http) = try await send(request("v1/sync", method: "POST", accessToken: accessToken, body: body))
        try ensureOK(data, http)
        let decoded = try decode(SyncResponseBody.self, data)
        return SyncResponse(
            ackedUuids: decoded.ackedUuids,
            events: decoded.events.map { $0.toModel() },
            newLastServerSeq: decoded.newLastServerSeq,
            moreToPull: decoded.more ?? false,
            configJSON: try decoded.config.jsonText(),
            activeChallengeConflict: decoded.activeChallengeConflict.map {
                ActiveChallengeConflict(
                    archivedChallengeId: $0.archivedChallengeId,
                    winnerChallengeId: $0.winnerChallengeId
                )
            }
        )
    }

    // MARK: Entitlement & account

    /// `GET /v1/entitlement` — read the account's own entitlement (never gated).
    func entitlement(accessToken: String) async throws -> Entitlement {
        let (data, http) = try await send(request("v1/entitlement", method: "GET", accessToken: accessToken, body: nil))
        try ensureOK(data, http)
        let body = try decode(EntitlementBody.self, data)
        return Entitlement(entitled: body.entitled, betaAllEntitled: body.betaAllEntitled)
    }

    /// `DELETE /v1/account` — wipe the account server-side (local data untouched).
    func deleteAccount(accessToken: String) async throws {
        let (data, http) = try await send(request("v1/account", method: "DELETE", accessToken: accessToken, body: nil))
        try ensureOK(data, http)
    }

    // MARK: Groups (docs/PHASE2.md "Groups"; all authed + entitlement-gated)

    /// `POST /v1/groups {name, display_name}` — create a group; the creator
    /// auto-joins. Returns the new group's id/name/invite code.
    func createGroup(name: String, displayName: String, accessToken: String) async throws -> GroupRef {
        let body = try encoder.encode(CreateGroupBody(name: name, displayName: displayName))
        let (data, http) = try await send(request("v1/groups", method: "POST", accessToken: accessToken, body: body))
        try ensureOK(data, http)
        return try decode(GroupRef.self, data)
    }

    /// `POST /v1/groups/join {invite_code, display_name}` — join by code
    /// (case-insensitive, idempotent; re-join updates the display name). An
    /// unknown code is a plain 404 — no "code exists but…" signal.
    func joinGroup(code: String, displayName: String, accessToken: String) async throws -> GroupRef {
        let body = try encoder.encode(JoinGroupBody(inviteCode: code, displayName: displayName))
        let (data, http) = try await send(request("v1/groups/join", method: "POST", accessToken: accessToken, body: body))
        try ensureOK(data, http)
        return try decode(GroupRef.self, data)
    }

    /// `GET /v1/groups` — the groups I belong to.
    func myGroups(accessToken: String) async throws -> [GroupSummary] {
        let (data, http) = try await send(request("v1/groups", method: "GET", accessToken: accessToken, body: nil))
        try ensureOK(data, http)
        return try decode(GroupsListBody.self, data).groups
    }

    /// `GET /v1/groups/:id` — members' minimal day-state DTOs. The requester
    /// must be a member, else the server returns 404 (group existence never
    /// leaks), which surfaces here as `.client(status: 404, …)`.
    func group(id: String, accessToken: String) async throws -> GroupDetail {
        let (data, http) = try await send(request("v1/groups/\(pathSegment(id))", method: "GET", accessToken: accessToken, body: nil))
        try ensureOK(data, http)
        return try decode(GroupDetail.self, data)
    }

    /// `POST /v1/groups/:id/leave` — 204. Server-side this drops my nudges in
    /// the group and deletes the group if I was the last member out.
    func leaveGroup(id: String, accessToken: String) async throws {
        let (data, http) = try await send(request("v1/groups/\(pathSegment(id))/leave", method: "POST", accessToken: accessToken, body: nil))
        try ensureOK(data, http)
    }

    /// `POST /v1/groups/:id/nudge {to_member_handle}` — 204. The recipient is
    /// named by their opaque per-group handle (from the member list), never the
    /// global account id. Both must be members (else 404); a self-nudge is 400;
    /// a repeat within the cooldown is 429.
    func nudge(groupId: String, toMemberHandle: String, accessToken: String) async throws {
        let body = try encoder.encode(NudgeBody(toMemberHandle: toMemberHandle))
        let (data, http) = try await send(request("v1/groups/\(pathSegment(groupId))/nudge", method: "POST", accessToken: accessToken, body: body))
        try ensureOK(data, http)
    }

    /// `GET /v1/nudges` — deliver pending in-app nudges once; the server marks
    /// them seen in the same transaction. Safe to poll (empty after the first).
    func pendingNudges(accessToken: String) async throws -> [PendingNudge] {
        let (data, http) = try await send(request("v1/nudges", method: "GET", accessToken: accessToken, body: nil))
        try ensureOK(data, http)
        return try decode(NudgesBody.self, data).nudges
    }

    // MARK: Plumbing

    /// Percent-encodes a single path segment (group ids are hex today, but this
    /// keeps the URL well-formed regardless of what the server ever returns).
    private func pathSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }

    private func endpoint(_ path: String) -> URL {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + path) ?? baseURL
    }

    private func request(_ path: String, method: String, accessToken: String?, body: Data?) -> URLRequest {
        var req = URLRequest(url: endpoint(path))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw DromeAPIError.offline(error.localizedDescription)
        } catch {
            throw DromeAPIError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DromeAPIError.unexpected("non-HTTP response")
        }
        return (data, http)
    }

    /// Passes 2xx through; maps everything else to the typed error.
    private func ensureOK(_ data: Data, _ http: HTTPURLResponse) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let (code, message) = errorBody(data, status: http.statusCode)
        switch http.statusCode {
        case 401:
            throw DromeAPIError.unauthorized(code: code, message: message)
        case 402:
            throw DromeAPIError.notEntitled(message: message)
        case 400..<500:
            throw DromeAPIError.client(status: http.statusCode, code: code, message: message)
        default:
            throw DromeAPIError.server(status: http.statusCode, code: code, message: message)
        }
    }

    private func errorBody(_ data: Data, status: Int) -> (code: String, message: String) {
        if let body = try? decoder.decode(APIErrorBody.self, from: data) {
            return (body.error, body.message)
        }
        return ("http_\(status)", "Request failed (\(status)).")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DromeAPIError.decoding(String(describing: error))
        }
    }
}

// MARK: - Wire DTOs (snake_case, explicit keys — exact server JSON)

private struct AppleAuthBody: Encodable {
    let identityToken: String
    let nonce: String
    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case nonce
    }
}

private struct DevAuthBody: Encodable {
    let accountKey: String
    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
    }
}

private struct EmailRequestBody: Encodable {
    let email: String
}

private struct EmailVerifyBody: Encodable {
    let email: String
    let code: String
}

private struct RefreshBody: Encodable {
    let refreshToken: String
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct AuthResponseBody: Decodable {
    let accountId: Int64
    let accessToken: String
    let refreshToken: String
    let expiresAtEpoch: Int64
    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAtEpoch = "expires_at_epoch"
    }
    func toModel() -> AuthResponse {
        AuthResponse(
            accountId: accountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtEpoch: expiresAtEpoch
        )
    }
}

private struct EntitlementBody: Decodable {
    let entitled: Bool
    let betaAllEntitled: Bool
    enum CodingKeys: String, CodingKey {
        case entitled
        case betaAllEntitled = "beta_all_entitled"
    }
}

private struct APIErrorBody: Decodable {
    let error: String
    let message: String
}

// MARK: - Group request/response bodies (snake_case, explicit keys)

private struct CreateGroupBody: Encodable {
    let name: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
    }
}

private struct JoinGroupBody: Encodable {
    let inviteCode: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case inviteCode = "invite_code"
        case displayName = "display_name"
    }
}

private struct NudgeBody: Encodable {
    let toMemberHandle: String
    enum CodingKeys: String, CodingKey {
        case toMemberHandle = "to_member_handle"
    }
}

private struct GroupsListBody: Decodable {
    let groups: [GroupSummary]
}

private struct NudgesBody: Decodable {
    let nudges: [PendingNudge]
}

/// One event on the wire. Bridges the camelCase Swift `WireEvent` to the
/// server's snake_case JSON via explicit keys (a `nil` `effectiveDate` is
/// omitted — serde reads a missing `Option` field as `None`).
private struct APIWireEvent: Codable {
    let uuid: String
    let challengeId: String
    let loggedAtEpoch: Int64
    let tzOffsetSecs: Int32
    let effectiveDate: String?
    let kind: String
    let payloadJson: String
    let schemaVersion: Int64

    enum CodingKeys: String, CodingKey {
        case uuid
        case challengeId = "challenge_id"
        case loggedAtEpoch = "logged_at_epoch"
        case tzOffsetSecs = "tz_offset_secs"
        case effectiveDate = "effective_date"
        case kind
        case payloadJson = "payload_json"
        case schemaVersion = "schema_version"
    }

    init(_ e: WireEvent) {
        uuid = e.uuid
        challengeId = e.challengeId
        loggedAtEpoch = e.loggedAtEpoch
        tzOffsetSecs = e.tzOffsetSecs
        effectiveDate = e.effectiveDate
        kind = e.kind
        payloadJson = e.payloadJson
        schemaVersion = e.schemaVersion
    }

    func toModel() -> WireEvent {
        WireEvent(
            uuid: uuid,
            challengeId: challengeId,
            loggedAtEpoch: loggedAtEpoch,
            tzOffsetSecs: tzOffsetSecs,
            effectiveDate: effectiveDate,
            kind: kind,
            payloadJson: payloadJson,
            schemaVersion: schemaVersion
        )
    }
}

private struct SyncRequestBody: Encodable {
    let deviceId: String
    let lastServerSeq: Int64
    let events: [APIWireEvent]
    let config: RawJSON
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case lastServerSeq = "last_server_seq"
        case events
        case config
    }
}

private struct SyncResponseBody: Decodable {
    let ackedUuids: [String]
    let events: [APIWireEvent]
    let newLastServerSeq: Int64
    /// Optional so an older server that omits it decodes as "no more".
    let more: Bool?
    let config: RawJSON
    let activeChallengeConflict: APIActiveChallengeConflict?
    enum CodingKeys: String, CodingKey {
        case ackedUuids = "acked_uuids"
        case events
        case newLastServerSeq = "new_last_server_seq"
        case more
        case config
        case activeChallengeConflict = "active_challenge_conflict"
    }
}

private struct APIActiveChallengeConflict: Decodable {
    let archivedChallengeId: String
    let winnerChallengeId: String
    enum CodingKeys: String, CodingKey {
        case archivedChallengeId = "archived_challenge_id"
        case winnerChallengeId = "winner_challenge_id"
    }
}

// MARK: - RawJSON passthrough (the core-owned config block)

/// A JSON value carried verbatim through Codable, so the exact bytes the Rust
/// core emits for `config` reach the server and the exact bytes the server
/// returns reach the core — no key transform, no re-typing of a schema the
/// core owns. Integers keep their integer form (serde rejects `1.0` for i64).
private struct RawJSON: Codable {
    let value: JSONValue

    init(jsonText: String) throws {
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8))
        } catch {
            throw DromeAPIError.unexpected("malformed config JSON")
        }
    }

    init(from decoder: Decoder) throws {
        value = try JSONValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    /// Re-serializes to compact JSON text for the core facade.
    func jsonText() throws -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw DromeAPIError.unexpected("could not re-serialize config JSON")
        }
    }
}

/// A fully general JSON value. Numbers preserve int-vs-double so whole numbers
/// re-encode without a spurious decimal point.
private indirect enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: JSONObjectKey.self) {
            var object: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let bool = try? single.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? single.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? single.decode(Double.self) {
            self = .double(double)
        } else if let string = try? single.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "unrecognized JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case .int(let value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case .double(let value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case .string(let value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case .array(let values):
            var c = encoder.unkeyedContainer()
            for value in values { try c.encode(value) }
        case .object(let object):
            var c = encoder.container(keyedBy: JSONObjectKey.self)
            for (key, value) in object {
                try c.encode(value, forKey: JSONObjectKey(stringValue: key))
            }
        }
    }
}

/// Dynamic string key for JSON objects (any key, no int keys).
private struct JSONObjectKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
