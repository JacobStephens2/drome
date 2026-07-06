//
//  KeychainSessionStore.swift
//  Drome
//
//  The ONLY place bearer/refresh tokens live at rest (docs/PHASE2.md "Auth").
//  Stored as one `kSecClassGenericPassword` item, this-device-only (never
//  synced to iCloud, never in a backup restored to another device). Tokens are
//  NEVER written to UserDefaults or logged — the app-facing display label is a
//  separate, non-sensitive value AppModel keeps elsewhere.
//

import Foundation
import Security

/// The credentials one signed-in session needs. `accountId` doubles as the
/// sync watermark context, so pull/push cursors are scoped per account. The
/// optional display `label` (which may be a real email Apple offered once) is
/// kept HERE, in the this-device Keychain item, never in UserDefaults — it is
/// PII and must not sit in cleartext defaults or unencrypted backups.
struct SessionTokens: Equatable, Sendable {
    var accountId: Int64
    var accessToken: String
    var refreshToken: String
    var label: String?
}

/// Loads/saves/clears the session in the Keychain. All operations are
/// synchronous and cheap; failures are non-fatal (a missing item just reads as
/// "signed out").
final class KeychainSessionStore {

    /// Distinct service so the item can't collide with anything else the app
    /// might store; a single fixed account key means one session at a time.
    private let service: String
    private let account = "session"

    init(service: String = "day.drome.app.session") {
        self.service = service
    }

    /// Persists the session, replacing any existing one. Accessible after first
    /// unlock (so a background sync can read it) but NEVER off-device.
    func save(_ tokens: SessionTokens) throws {
        let data = try JSONEncoder().encode(StoredSession(tokens))
        // Delete-then-add keeps the accessibility attribute authoritative.
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// The stored session, or nil when signed out (or on any read failure —
    /// a corrupt/unreadable item is treated as no session, never a crash).
    func load() -> SessionTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else { return nil }
        return stored.tokens
    }

    /// Removes the session (sign out / delete account). Idempotent.
    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

/// On-disk shape (Codable so the item is a self-describing blob, versioned for
/// forward compatibility).
private struct StoredSession: Codable {
    var version: Int
    var accountId: Int64
    var accessToken: String
    var refreshToken: String
    /// Optional so a v1 item written before the label lived here still decodes
    /// (Codable reads a missing optional as nil).
    var label: String?

    init(_ tokens: SessionTokens) {
        version = 2
        accountId = tokens.accountId
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        label = tokens.label
    }

    var tokens: SessionTokens {
        SessionTokens(
            accountId: accountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            label: label
        )
    }
}
