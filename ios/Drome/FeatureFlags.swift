//
//  FeatureFlags.swift
//  Drome
//
//  Build-time gating for features that aren't ready to ship to everyone yet.
//

import Foundation

enum FeatureFlags {

    /// Server-backed features — Sign in with Apple, cross-device sync, and
    /// friend groups — depend on the deployed drome-server. Until that server
    /// is live, they must stay hidden in Release/TestFlight builds so testers
    /// never meet a Sign-in button that dead-ends against an unreachable host.
    ///
    /// ON in DEBUG (local development against a locally-run server); OFF in
    /// Release by default. To turn them on for a release build once the server
    /// is deployed, either flip the `#else` return to `true`, or set the
    /// "DromeServerFeatures" UserDefault (for a staged rollout).
    static var serverFeatures: Bool {
        #if DEBUG
        // Preview the Release-gated (server-off) UI on the simulator:
        //   xcrun simctl launch booted day.drome.app -drome-hide-server-features
        if ProcessInfo.processInfo.arguments.contains("-drome-hide-server-features") {
            return false
        }
        return true
        #else
        return UserDefaults.standard.bool(forKey: "DromeServerFeatures")
        #endif
    }
}
