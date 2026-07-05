//
//  RootView.swift
//  Drome
//
//  The running app: three tabs (Today / History / Settings), feature-sheet
//  routing off the day board, completion moments, and the anti-chug alert.
//  TODAY = DayBoardView with its closures wired into sheets; a toolbar share
//  button renders today's ShareCardSheet. HISTORY = HistoryView. SETTINGS =
//  SettingsView. The daily CompletionMomentView presents full-screen; the
//  smaller WeeklyMomentView is always junior — it waits until no daily
//  moment is pending.
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    private enum Tab: Hashable {
        case today, history, settings
    }

    private enum TodaySheet: Identifiable {
        case water
        case workouts
        case reading
        case photo
        case yesterday
        case share(ShareCardData)

        var id: String {
            switch self {
            case .water: return "water"
            case .workouts: return "workouts"
            case .reading: return "reading"
            case .photo: return "photo"
            case .yesterday: return "yesterday"
            case .share(let data): return "share-\(data.date)"
            }
        }
    }

    @State private var tab: Tab = .today
    @State private var sheet: TodaySheet?

    var body: some View {
        @Bindable var appModel = appModel
        TabView(selection: $tab) {
            todayTab
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(Tab.today)

            NavigationStack {
                HistoryView(client: appModel.client)
            }
            .tabItem { Label("History", systemImage: "calendar") }
            .tag(Tab.history)

            NavigationStack {
                SettingsView(client: appModel.client)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .tint(Color.dromeClay)
        .task {
            appModel.refresh()
            applyDebugLaunchScreen()
        }
        .sheet(item: $sheet) { presented in
            sheetContent(presented)
        }
        .fullScreenCover(item: $appModel.pendingCompletionMoment) { moment in
            CompletionMomentView(
                dayIndex: moment.dayIndex,
                currentRun: moment.currentRun,
                onDismiss: { appModel.pendingCompletionMoment = nil }
            )
        }
        .overlay { weeklyMomentOverlay }
        // A completing log can land while a feature sheet is up (e.g. the
        // final ounce inside WaterView). Dismiss the sheet so the full-screen
        // moment can take over.
        .onChange(of: appModel.pendingCompletionMoment) { _, moment in
            if moment != nil { sheet = nil }
        }
        .alert(
            "Over a liter in an hour",
            isPresented: Binding(
                get: { appModel.pendingChugWarning != nil && sheet == nil },
                set: { if !$0 { appModel.cancelPendingWater() } }
            ),
            presenting: appModel.pendingChugWarning
        ) { _ in
            Button("Log anyway") { appModel.confirmPendingWater() }
            Button("Wait", role: .cancel) { appModel.cancelPendingWater() }
        } message: { warning in
            Text("That would be over \(warning.limitMl) ml in the last hour. Your body handles about 1 liter an hour — it counts just the same in a while.")
        }
    }

    // MARK: - Today tab

    private var todayTab: some View {
        NavigationStack {
            DayBoardView(
                onOpenWater: { sheet = .water },
                onOpenWorkouts: { sheet = .workouts },
                onOpenReading: { sheet = .reading },
                onOpenPhoto: { sheet = .photo },
                onLogYesterday: { sheet = .yesterday }
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: presentTodayShareCard) {
                        Image(systemName: "square.and.arrow.up")
                            .fontWeight(.semibold)
                    }
                    .disabled(appModel.todayState == nil)
                    .accessibilityLabel("Share today's card")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func presentTodayShareCard() {
        guard let date = appModel.todayState?.date,
              let data = try? appModel.client.shareCard(date: date) else { return }
        sheet = .share(data)
    }

    // MARK: - Sheet routing

    @ViewBuilder
    private func sheetContent(_ sheet: TodaySheet) -> some View {
        switch sheet {
        case .water:
            WaterView()
        case .workouts:
            WorkoutView { entry in
                appModel.revoke(eventUuid: entry.id)
            }
        case .reading:
            ReadingView(client: appModel.client)
        case .photo:
            PhotoView(client: appModel.client)
        case .yesterday:
            YesterdayLogSheet()
        case .share(let data):
            ShareCardSheet(data: data)
        }
    }

    // MARK: - Weekly moment (junior to the daily moment, never simultaneous)

    @ViewBuilder
    private var weeklyMomentOverlay: some View {
        if let moment = appModel.pendingWeeklyMoment, appModel.pendingCompletionMoment == nil {
            WeeklyMomentView(
                weekIndex: moment.weekIndex,
                extraName: moment.extraName,
                onDismiss: { appModel.pendingWeeklyMoment = nil }
            )
            .transition(.opacity)
        }
    }

    // MARK: - DEBUG screenshot routing (-drome-screen <name>)

    private func applyDebugLaunchScreen() {
        #if DEBUG
        guard let screen = DromeDebugLaunch.requestedScreen else { return }
        switch screen {
        case .water: sheet = .water
        case .workout: sheet = .workouts
        case .reading: sheet = .reading
        case .history: tab = .history
        case .settings: tab = .settings
        case .share: presentTodayShareCard()
        }
        #endif
    }
}

// MARK: - Yesterday sheet (retroactive one-tap logging, honestly labeled)

/// Compact "log for yesterday" sheet: the five task tiles (workout tile =
/// two slots) as one-tap buttons writing with `effectiveDate` = yesterday.
/// This edits yesterday only — the header says so plainly.
private struct YesterdayLogSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var yesterdayDate: DayDate?
    @State private var day: DayState?

    var body: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.m) {
            header

            if let day {
                VStack(spacing: DromeSpacing.s) {
                    waterRow(day)
                    taskRow(
                        done: day.outdoorWorkoutDone,
                        title: "Outdoor workout",
                        buttonLabel: "Log 45 min"
                    ) { log { appModel.logWorkout(durationMin: 45, outdoor: true, effectiveDate: $0) } }
                    taskRow(
                        done: day.secondWorkoutDone,
                        title: "Second workout",
                        buttonLabel: "Log 30 min"
                    ) { log { appModel.logWorkout(durationMin: 30, outdoor: false, effectiveDate: $0) } }
                    taskRow(
                        done: day.readingDone,
                        title: "Reading",
                        detail: "\(day.pagesRead) of 10 pages",
                        buttonLabel: "+10 pages"
                    ) { log { appModel.logReading(pages: 10, effectiveDate: $0) } }
                    taskRow(
                        done: day.dietDone,
                        title: "Diet",
                        buttonLabel: "Kept it"
                    ) { log { appModel.logDietOk(effectiveDate: $0) } }
                    taskRow(
                        done: day.photoDone,
                        title: "Progress photo",
                        buttonLabel: "Taken"
                    ) { log { appModel.logPhotoDone(effectiveDate: $0) } }
                }
            } else {
                Text("Couldn't load yesterday.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }

            Spacer(minLength: 0)
        }
        .padding(DromeSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dromeSand.ignoresSafeArea())
        .presentationDetents([.large])
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("EDITING YESTERDAY")
                .font(.system(size: 12, weight: .black))
                .tracking(1.4)
                .foregroundStyle(Color.dromeClay)
            if let day {
                Text("Day \(day.dayIndex) — \(Self.displayDate(day.date))")
                    .font(.system(size: 22, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.3)
                    .foregroundStyle(Color.dromeInk)
            }
            Text("Everything you log here counts toward yesterday, not today.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
    }

    // MARK: Rows

    private func waterRow(_ day: DayState) -> some View {
        let remaining = max(0, day.waterGoalMl - day.waterTotalMl)
        let remainingOz = Int(WaterUnits.flOz(fromMl: remaining).rounded(.up))
        return taskRow(
            done: day.waterDone,
            title: "Water",
            detail: "\(Int(WaterUnits.flOz(fromMl: day.waterTotalMl).rounded())) of \(Int(WaterUnits.flOz(fromMl: day.waterGoalMl).rounded())) oz",
            buttonLabel: "Met goal (+\(remainingOz) oz)"
        ) {
            guard remaining > 0 else { return }
            log { appModel.logWater(ml: remaining, effectiveDate: $0) }
        }
    }

    private func taskRow(
        done: Bool,
        title: String,
        detail: String? = nil,
        buttonLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DromeSpacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(done ? Color.dromeDone : Color.dromeInk.opacity(0.3))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.dromeInk)
                if let detail {
                    Text(detail)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeInk.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
            if done {
                Text("Done")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.dromeDone)
            } else if yesterdayDate != nil {
                Button(action: action) {
                    Text(buttonLabel)
                        .font(.footnote.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeClay)
                        .padding(.horizontal, DromeSpacing.m)
                        .frame(minHeight: DromeSpacing.tapTarget)
                        .background(Capsule().strokeBorder(Color.dromeClay, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(buttonLabel), for yesterday")
            }
        }
        .padding(.horizontal, DromeSpacing.m)
        .padding(.vertical, DromeSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(done ? Color.dromeDone.opacity(0.10) : Color.dromeInk.opacity(0.05))
        )
    }

    // MARK: Data

    /// Runs an AppModel intent, then reloads yesterday's projection (the
    /// intent already refreshed the model's own caches).
    private func log(_ intent: (DayDate) -> Void) {
        guard let date = yesterdayDate else { return }
        intent(date)
        day = try? appModel.client.dayState(date: date)
    }

    private func load() {
        guard let today = appModel.todayState?.date,
              let date = Self.shift(today, by: -1) else { return }
        yesterdayDate = date
        day = try? appModel.client.dayState(date: date)
    }

    // MARK: Date plumbing (display only; attribution stays in core)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func shift(_ date: DayDate, by days: Int) -> DayDate? {
        guard let base = dayFormatter.date(from: date),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return dayFormatter.string(from: shifted)
    }

    private static func displayDate(_ date: DayDate) -> String {
        guard let parsed = dayFormatter.date(from: date) else { return date }
        return parsed.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

// MARK: - Previews

#Preview {
    RootView()
        .environment(AppModel())
}

#Preview("Dark") {
    RootView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}
