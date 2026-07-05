//
//  DebugLaunch.swift
//  Drome
//
//  DEBUG-only verification hooks (documented in CLAUDE.md, build commands):
//
//    -drome-demo-seed          when the store has no challenge, seed the
//                              demo fixture through the REAL client so
//                              today is Day 14 mid-challenge.
//    -drome-screen <name>      water|workout|reading|history|settings|share —
//                              present that screen on launch (screenshots).
//
//  Everything here is compiled out of Release builds.
//

#if DEBUG

import Foundation

enum DromeDebugLaunch {

    // MARK: - Launch-argument parsing

    enum Screen: String {
        case water, workout, reading, history, settings, share
    }

    static var requestedScreen: Screen? {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-drome-screen"),
              args.indices.contains(flag + 1) else { return nil }
        return Screen(rawValue: args[flag + 1])
    }

    private static var demoSeedRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-drome-demo-seed")
    }

    // MARK: - Demo seed (demo fixture through the real client)

    /// Start = today − 13 days (today is Day 14). Days 1–12 backfilled
    /// all-complete (job application in week 1), day 13 all-but-reading.
    /// Today: 1420 ml water + one 45-min outdoor workout already logged.
    /// No-op unless `-drome-demo-seed` is passed AND the store is empty.
    static func seedIfRequested(client: DromeCoreClient) {
        guard demoSeedRequested else { return }
        do {
            guard try client.activeChallenge() == nil else { return }

            var cfg = NewChallenge()
            cfg.startDate = shift(localDate(cutoffMinutes: cfg.dayCutoffMinutes), by: -13)
            cfg.dietDescription = "no junk, no alcohol"
            cfg.currentBook = "Atomic Habits"
            let challenge = try client.createChallenge(cfg)

            try client.updatePresets([
                ContainerPreset(id: "bottle-32oz", name: "32 oz bottle", ml: 946, sortOrder: 0),
                ContainerPreset(id: "glass", name: "Glass", ml: 350, sortOrder: 1),
            ])
            // Fixed Phase 1 weekly-extra preset def; tolerate a core without it.
            try? client.setExtraEnabled(id: "job_application", enabled: true)

            var days: [BackfilledDay] = []
            for offset in 0..<13 {
                days.append(BackfilledDay(
                    date: shift(challenge.startDate, by: offset),
                    water: true,
                    outdoorWorkout: true,
                    secondWorkout: true,
                    reading: offset < 12, // day 13 (offset 12): all but reading
                    diet: true,
                    photo: true,
                    extraIds: offset == 4 ? ["job_application"] : []
                ))
            }
            try client.backfillDays(days)

            // Today (Day 14): partial. LogResults (incl. any chug flag from
            // two quick pours) are intentionally ignored — this is seeding.
            _ = try client.logWater(ml: 946, effectiveDate: nil)
            _ = try client.logWater(ml: 946, effectiveDate: nil)
            _ = try client.logWorkout(durationMin: 45, outdoor: true, note: "Morning run", effectiveDate: nil)
        } catch {
            // A failed seed must never take down a debug launch; the app just
            // shows onboarding and the console says why.
            print("drome-demo-seed failed: \(error)")
        }
    }

    // MARK: - Date helpers (calendar-date only; attribution stays in core)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local "today" under the given day cutoff (mirrors the core's step-2
    /// attribution, same as LiveDromeCore's NewChallenge default).
    private static func localDate(cutoffMinutes: Int) -> DayDate {
        dayFormatter.string(from: Date().addingTimeInterval(TimeInterval(-cutoffMinutes * 60)))
    }

    private static func shift(_ date: DayDate, by days: Int) -> DayDate {
        guard let base = dayFormatter.date(from: date),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: base)
        else { return date }
        return dayFormatter.string(from: shifted)
    }
}

#endif
