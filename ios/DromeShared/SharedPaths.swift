//
//  SharedPaths.swift
//  DromeShared
//
//  Single source of truth for the on-disk location of the shared SQLite DB
//  (docs/ARCHITECTURE.md): `<App Group container>/drome.sqlite`, WAL mode,
//  so app + widget share one store across processes. Falls back to the
//  process's Application Support directory when the group container is
//  unavailable (e.g. some simulator configs). Compiled into both the app
//  and widget targets; LiveDromeCore opens `SharedPaths.databasePath`.
//

import Foundation

enum SharedPaths {
    /// App Group shared by the app (`day.drome.app`) and widget
    /// (`day.drome.app.widget`).
    static let appGroupID = "group.day.drome.app"

    /// SQLite filename inside the container.
    static let databaseFileName = "drome.sqlite"

    /// Directory the database lives in: the App Group container when
    /// available, else Application Support (created on demand).
    static var databaseDirectoryURL: URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// Full URL of the shared database file.
    static var databaseURL: URL {
        databaseDirectoryURL.appendingPathComponent(databaseFileName, isDirectory: false)
    }

    /// Path string in the form `DromeStore::open(db_path)` expects.
    static var databasePath: String {
        databaseURL.path
    }
}
