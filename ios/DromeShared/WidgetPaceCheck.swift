//
//  WidgetPaceCheck.swift
//  DromeShared
//
//  Pace-check flag shared between the app and the water widget (App Group
//  UserDefaults). A widget has no room for the anti-chug confirmation dialog,
//  so when the facade's chug check warns, LogWaterIntent logs NOTHING and
//  raises this flag; the next widget render shows the "Open Drome — pace
//  check" state. The flag expires with the chug guard's trailing-hour window,
//  clears on the widget's next successful log, and clears when the user logs
//  water in the app (they've seen the full dialog there).
//

import Foundation

enum WidgetPaceCheck {
    private static let key = "widget.paceCheckPendingAt"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedPaths.appGroupID) ?? .standard
    }

    static func setPending(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: key)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }

    static var isPending: Bool {
        let raisedAt = defaults.double(forKey: key)
        guard raisedAt > 0 else { return false }
        return Date().timeIntervalSince1970 - raisedAt < 3600
    }
}
