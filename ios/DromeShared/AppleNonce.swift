import CryptoKit
import Foundation

/// A Sign-in-with-Apple replay-nonce pair (docs/PHASE2.md "Auth").
///
/// The SwiftUI SIWA button (built in a later stage) sets
/// `ASAuthorizationAppleIDRequest.nonce = hashedForApple`; Apple returns an
/// identity token whose `nonce` claim is that hash. The app then POSTs `raw` to
/// `POST /v1/auth/apple` as the request's `nonce` field, and the server rebinds
/// `sha256(raw) == claim` before issuing a session. Only the app ever holds
/// `raw`, so a captured identity token can't be replayed by anyone else.
///
/// This is the facade the account/SyncEngine layer consumes; it needs no core
/// call (auth crosses the wire via URLSession, not the Rust core). `sha256Hex`
/// mirrors the server's hashing exactly (SHA-256 of the UTF-8 bytes, lowercase
/// hex), so a pair generated here always verifies server-side.
struct AppleNonce: Sendable, Equatable {
    /// The random nonce the app keeps and sends to `/v1/auth/apple`.
    let raw: String
    /// `sha256(raw)` in lowercase hex — the value handed to Apple.
    let hashedForApple: String

    /// Generates a fresh nonce pair from the system CSPRNG
    /// (`SystemRandomNumberGenerator` is cryptographically secure on Apple
    /// platforms).
    static func generate() -> AppleNonce {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let raw = hex(bytes)
        return AppleNonce(raw: raw, hashedForApple: sha256Hex(raw))
    }

    /// SHA-256 of `input`'s UTF-8 bytes, lowercase hex — the exact form the
    /// server compares against the identity token's `nonce` claim.
    static func sha256Hex(_ input: String) -> String {
        hex(Array(SHA256.hash(data: Data(input.utf8))))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
