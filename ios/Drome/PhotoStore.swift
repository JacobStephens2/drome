//
//  PhotoStore.swift
//  Drome
//
//  The app-private progress-photo file store (Application Support/photos/).
//  The core keeps only a ref string (the filename); this is THE one place
//  that maps a day/ref to its file and deletes orphans — shared by PhotoView
//  (attach + thumbnail) and AppModel (deleting revoked photo events' JPEGs,
//  via LogResult.revokedPhotoRefs). Photos stay on this device and never
//  appear in share cards.
//

import Foundation

enum PhotoStore {

    /// Application Support/photos/, created on first use.
    static func directory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Canonical photoRef (bare filename) for a given day's photo.
    static func ref(for date: DayDate) -> String {
        "\(date).jpg"
    }

    /// Resolves a stored photoRef to its file URL. Refs are bare filenames
    /// minted by this app; anything path-like is rejected rather than letting
    /// a stray ref reach outside the photos directory.
    static func url(forRef ref: String) -> URL? {
        guard !ref.isEmpty, !ref.contains("/"), !ref.contains(".."),
              let directory = try? directory() else { return nil }
        return directory.appendingPathComponent(ref)
    }

    /// Best-effort delete of a ref's file. Used when the backing photo event
    /// is revoked — the JPEG would otherwise linger and masquerade as that
    /// day's photo.
    static func deleteFile(forRef ref: String) {
        guard let url = url(forRef: ref) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the entire photos directory — every progress photo on this
    /// phone. Used ONLY by the app reset (`AppModel.resetApp()`). Unlike
    /// `deleteFile` this is NOT silent best-effort: the reset flow promised
    /// "every progress photo on this phone", so a survivor must be reported,
    /// never swallowed. Returns true only when the directory is verifiably
    /// gone (retrying the delete once); `directory()` recreates the folder
    /// on next use.
    @discardableResult
    static func deleteAllFiles() -> Bool {
        guard let directory = try? directory() else {
            // Application Support itself is unreachable, so nothing can be
            // verified deleted — report failure (honest beats optimistic in
            // the one destructive flow).
            return false
        }
        for _ in 0..<2 {
            try? FileManager.default.removeItem(at: directory)
            if !FileManager.default.fileExists(atPath: directory.path) {
                return true
            }
        }
        return false
    }
}
