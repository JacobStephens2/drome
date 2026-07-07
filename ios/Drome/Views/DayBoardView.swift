//
//  DayBoardView.swift
//  Drome
//
//  Home-screen day board: "DAY N" header with date + current run, a one-line
//  "what's left" strip, the six core task tiles (each showing its real data
//  shape — see DayBoardTiles.swift), and any enabled weekly extra rendered
//  visibly secondary. Day lifecycle affordances: a "log for yesterday"
//  banner whenever yesterday is neither closed nor complete (per the
//  contract, yesterday stays editable until it's closed), an info banner
//  once today is closed, and a quiet "close out my day" button when all
//  seven slots are done (the toolbar menu in RootView offers it any time).
//
//  Navigation is NOT wired here: water/workouts/reading/photo hand off via
//  closure callbacks (integration stage connects them to their features).
//  Everything else — attests and their toggle-offs (diet, no-junk, photo,
//  weekly extra via revokeTask), workout slot check/undo, and close-day —
//  goes straight through AppModel intents, so every task completes and
//  un-completes through the same honest path.
//

import SwiftUI

struct DayBoardView: View {
    @Environment(AppModel.self) private var appModel

    @State private var closeConfirmPresented = false

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
                    if yesterdayNeedsFinishing {
                        yesterdayBanner
                    }
                    whatsLeftStrip(today.day)
                    tiles(today)
                    ForEach(today.weekExtras) { extra in
                        // Toggle-off targets the date the extra's live event
                        // sits on (it may have been done earlier this week);
                        // AppModel resolves that per refresh. Backfill-flag
                        // extras never appear in the map — done, not
                        // tappable-off.
                        DayBoardWeekExtraTile(
                            state: extra,
                            weekIndex: today.weekIndex,
                            canRevoke: appModel.weekExtraRevocableDates[extra.id] != nil,
                            onMarkDone: { appModel.logExtraDone(id: extra.id) },
                            onRevoke: {
                                guard let date = appModel.weekExtraRevocableDates[extra.id] else { return }
                                appModel.revokeTask(.extra(id: extra.id), date: date)
                            }
                        )
                    }
                    if today.day.coreComplete && !today.day.isClosed {
                        closeDayButton
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
        // Closing can't be un-done from the UI, so it asks once, plainly.
        .confirmationDialog(
            "Close out Day \(appModel.todayState?.dayIndex ?? 0)?",
            isPresented: $closeConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Close the day") { appModel.closeDay() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything you log after this counts toward tomorrow.")
        }
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
                    Text("All seven done.")
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
        if !day.secondWorkoutDone { items.append("indoor/outdoor workout") }
        if !day.readingDone { items.append(DayBoardFormat.pagesLeftLabel(day.pagesRead)) }
        if !day.dietDone { items.append("diet") }
        if !day.noJunkDone { items.append("no junk") }
        if !day.photoDone { items.append("photo") }
        return items
    }

    // MARK: - Day lifecycle (closed banner, yesterday affordance, close-out)

    /// Info-only: today is closed, later logs roll to tomorrow. The "log for
    /// yesterday" affordance lives in `yesterdayBanner`, keyed off
    /// yesterday's actual state, not today's.
    private func closedBanner(_ today: TodayState) -> some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("Day \(today.dayIndex) is closed")
                .font(.subheadline.weight(.black))
                .monospacedDigit()
                .foregroundStyle(Color.dromeInk)
            Text("New logs count toward tomorrow.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Per the contract, yesterday stays editable until it's closed — offer
    /// the retroactive sheet whenever yesterday is neither closed nor
    /// complete (and is a real challenge day).
    private var yesterdayNeedsFinishing: Bool {
        guard let yesterday = appModel.yesterdayState else { return false }
        return !yesterday.isClosed && !yesterday.coreComplete && !yesterday.outOfRange
    }

    private var yesterdayBanner: some View {
        HStack(spacing: DromeSpacing.m) {
            VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                Text("Yesterday is still open")
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(Color.dromeInk)
                Text("Forgot to log something? It counts until you close the day.")
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

    /// Quiet close-out under the tiles, shown once all seven slots are done.
    /// "The day ends when you tell it you're done."
    private var closeDayButton: some View {
        Button {
            closeConfirmPresented = true
        } label: {
            Label("Close out my day", systemImage: "checkmark.seal")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.dromeInk.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.dromeInk.opacity(0.25), lineWidth: 1.5)
        )
    }

    // MARK: - Tiles

    private func tiles(_ today: TodayState) -> some View {
        VStack(spacing: DromeSpacing.s) {
            DayBoardWaterTile(day: today.day, onOpen: onOpenWater)
            DayBoardWorkoutsTile(
                day: today.day,
                onOpen: onOpenWorkouts,
                onLogSlot: { outdoor in
                    appModel.logWorkout(
                        durationMin: DayState.slotDefaultDurationMin,
                        outdoor: outdoor
                    )
                },
                onUndoEntry: { appModel.revoke(eventUuid: $0.id) }
            )
            DayBoardReadingTile(
                day: today.day,
                book: appModel.challenge?.currentBook ?? "",
                onOpen: onOpenReading
            )
            DayBoardDietTile(
                dietDescription: appModel.challenge?.dietDescription ?? "",
                done: today.day.dietDone,
                canRevoke: today.day.revocable.diet,
                onAttest: { appModel.logDietOk() },
                onRevoke: { appModel.revokeTask(.diet) }
            )
            DayBoardNoJunkTile(
                done: today.day.noJunkDone,
                canRevoke: today.day.revocable.noJunk,
                onAttest: { appModel.logNoJunkOk() },
                onRevoke: { appModel.revokeTask(.noJunk) }
            )
            DayBoardPhotoTile(
                done: today.day.photoDone,
                canRevoke: today.day.revocable.photo,
                onOpen: onOpenPhoto,
                onMarkDone: { appModel.logPhotoDone() },
                onRevoke: { appModel.revokeTask(.photo) }
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
    _ = try? core.logNoJunkOk()
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
