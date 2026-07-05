//
//  DayBoardView.swift
//  Drome
//
//  Home-screen day board: "DAY N" header with date + current run, a one-line
//  "what's left" strip, the five core task tiles (each showing its real data
//  shape — see DayBoardTiles.swift), and any enabled weekly extra rendered
//  visibly secondary. Day-closed state shows a banner with a "log for
//  yesterday" affordance.
//
//  Navigation is NOT wired here: water/workouts/reading/photo hand off via
//  closure callbacks (integration stage connects them to their features).
//  Diet attest, photo check-off, and weekly-extra done go straight through
//  AppModel intents.
//

import SwiftUI

struct DayBoardView: View {
    @Environment(AppModel.self) private var appModel

    private let onOpenWater: () -> Void
    private let onOpenWorkouts: () -> Void
    private let onOpenReading: () -> Void
    private let onOpenPhoto: () -> Void
    private let onLogYesterday: () -> Void

    init(
        onOpenWater: @escaping () -> Void = {},
        onOpenWorkouts: @escaping () -> Void = {},
        onOpenReading: @escaping () -> Void = {},
        onOpenPhoto: @escaping () -> Void = {},
        onLogYesterday: @escaping () -> Void = {}
    ) {
        self.onOpenWater = onOpenWater
        self.onOpenWorkouts = onOpenWorkouts
        self.onOpenReading = onOpenReading
        self.onOpenPhoto = onOpenPhoto
        self.onLogYesterday = onLogYesterday
    }

    var body: some View {
        ScrollView {
            if let today = appModel.todayState {
                VStack(alignment: .leading, spacing: DromeSpacing.m) {
                    header(today)
                    if today.day.isClosed {
                        closedBanner(today)
                    }
                    whatsLeftStrip(today.day)
                    tiles(today)
                    ForEach(today.weekExtras) { extra in
                        DayBoardWeekExtraTile(
                            state: extra,
                            weekIndex: today.weekIndex,
                            onMarkDone: { appModel.logExtraDone(id: extra.id) }
                        )
                    }
                }
                .padding(.horizontal, DromeSpacing.m)
                .padding(.top, DromeSpacing.m)
                .padding(.bottom, DromeSpacing.xl)
            } else {
                placeholder
            }
        }
        .background(Color.dromeSand.ignoresSafeArea())
        .onAppear { appModel.refresh() }
    }

    // MARK: - Header

    private func header(_ today: TodayState) -> some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.s) {
                Text("DAY \(today.dayIndex)")
                    .dromeCounter()
                Text("of \(appModel.summary?.lengthDays ?? appModel.challenge?.lengthDays ?? 75)")
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }
            Text(Self.displayDate(today.date))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.7))
            if let summary = appModel.summary {
                Text(summary.currentRun == 1
                     ? "Current run: 1 day"
                     : "Current run: \(summary.currentRun) days")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(summary.currentRun > 0 ? Color.dromeCamel : Color.dromeInk.opacity(0.6))
            }
        }
    }

    // MARK: - "What's left" strip

    private func whatsLeftStrip(_ day: DayState) -> some View {
        let items = openItems(day)
        return Group {
            if items.isEmpty {
                HStack(spacing: DromeSpacing.s) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("All six done.")
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.dromeDone)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.s) {
                    Text("LEFT")
                        .font(.caption.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(Color.dromeClay)
                    Text(items.joined(separator: " · "))
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeInk.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
        }
        .padding(.vertical, DromeSpacing.s)
        .padding(.horizontal, DromeSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dromeInk.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
    }

    private func openItems(_ day: DayState) -> [String] {
        var items: [String] = []
        if !day.waterDone {
            items.append("\(DayBoardFormat.ozLeft(total: day.waterTotalMl, goal: day.waterGoalMl)) oz")
        }
        if !day.outdoorWorkoutDone { items.append("outdoor workout") }
        if !day.secondWorkoutDone { items.append("2nd workout") }
        if !day.readingDone { items.append(DayBoardFormat.pagesLeftLabel(day.pagesRead)) }
        if !day.dietDone { items.append("diet") }
        if !day.photoDone { items.append("photo") }
        return items
    }

    // MARK: - Day-closed banner

    private func closedBanner(_ today: TodayState) -> some View {
        HStack(spacing: DromeSpacing.m) {
            VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                Text("Day \(today.dayIndex) is closed")
                    .font(.subheadline.weight(.black))
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk)
                Text("New logs count toward tomorrow.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }
            Spacer(minLength: 0)
            Button(action: onLogYesterday) {
                Text("Log for yesterday")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.dromeClay)
                    .padding(.horizontal, DromeSpacing.m)
                    .frame(minHeight: DromeSpacing.tapTarget)
                    .background(Capsule().strokeBorder(Color.dromeClay, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .padding(DromeSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.dromeCamel.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.dromeCamel.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Tiles

    private func tiles(_ today: TodayState) -> some View {
        VStack(spacing: DromeSpacing.s) {
            DayBoardWaterTile(day: today.day, onOpen: onOpenWater)
            DayBoardWorkoutsTile(day: today.day, onOpen: onOpenWorkouts)
            DayBoardReadingTile(
                day: today.day,
                book: appModel.challenge?.currentBook ?? "",
                onOpen: onOpenReading
            )
            DayBoardDietTile(
                dietDescription: appModel.challenge?.dietDescription ?? "",
                done: today.day.dietDone,
                onAttest: { appModel.logDietOk() }
            )
            DayBoardPhotoTile(
                done: today.day.photoDone,
                onOpen: onOpenPhoto,
                onMarkDone: { appModel.logPhotoDone() }
            )
        }
    }

    // MARK: - Placeholder (no active challenge / not yet refreshed)

    private var placeholder: some View {
        VStack(spacing: DromeSpacing.m) {
            Text("No active challenge")
                .dromeTitle()
            Text("Start a challenge to see your day board.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DromeSpacing.xl * 3)
    }

    // MARK: - Date formatting

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func displayDate(_ date: DayDate) -> String {
        guard let parsed = dayParser.date(from: date) else { return date }
        return parsed.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

// MARK: - Previews

#Preview("Partial day") {
    DayBoardView()
        .environment(AppModel())
}

#Preview("Partial day — dark") {
    DayBoardView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}

#Preview("Complete day") {
    // Drive the mock core directly so the board renders a fully-done day
    // without tripping AppModel's chug-confirmation flow.
    let core = MockDromeCore()
    _ = try? core.logWater(ml: 3000)
    _ = try? core.logWorkout(durationMin: 30, outdoor: false, note: "Lifting")
    _ = try? core.logReading(bookTitle: "Atomic Habits", pages: 12)
    _ = try? core.logDietOk()
    _ = try? core.logPhotoDone()
    _ = try? core.logExtraDone(extraId: "job_application")
    return DayBoardView()
        .environment(AppModel(core: core))
}

#Preview("Day closed") {
    let model = AppModel()
    model.refresh()
    model.closeDay()
    return DayBoardView()
        .environment(model)
}
