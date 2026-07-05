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
    @Environment(\.scenePhase) private var scenePhase

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
    @State private var closeDayConfirmPresented = false

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
        // Widget logs and day rollovers happen while the app is backgrounded;
        // re-project on every return to foreground so the board is never stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appModel.refresh() }
        }
        .sheet(item: $sheet) { presented in
            sheetContent(presented)
                // A failed intent inside a sheet (water/photo/yesterday…)
                // must alert on top of that sheet, not under it.
                .modifier(IntentErrorAlert(isFrontmost: true))
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
        // Fallback chug alert (matches WaterView's pattern): SwiftUI flips the
        // binding false BEFORE the tapped button's action runs, so the setter
        // must be a no-op — clearing pending state there would swallow a
        // confirmed "Log anyway". Both buttons clear the state explicitly.
        .alert(
            "Over 34 oz in an hour",
            isPresented: Binding(
                get: { appModel.pendingChugWarning != nil && sheet == nil },
                set: { _ in }
            ),
            presenting: appModel.pendingChugWarning
        ) { _ in
            Button("Log anyway") { appModel.confirmPendingWater() }
            Button("Wait", role: .cancel) { appModel.cancelPendingWater() }
        } message: { warning in
            // Ounces, matching WaterView's copy (display unit is fl oz;
            // ml stays the core's canonical unit).
            let limitOz = Int(WaterUnits.flOz(fromMl: warning.limitMl).rounded())
            Text("That would put you past about \(limitOz) oz within an hour. Kidneys process roughly 27–34 oz an hour — it counts just the same in a while.")
        }
        // Failed writes must never look like successful taps: any intent
        // error lands here as an honest alert. Yields to a presented sheet,
        // whose content carries its own copy of the same alert.
        .modifier(IntentErrorAlert(isFrontmost: sheet == nil))
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            closeDayConfirmPresented = true
                        } label: {
                            Label("Close out my day", systemImage: "checkmark.seal")
                        }
                        .disabled(appModel.todayState == nil || appModel.todayState?.day.isClosed == true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("More actions")
                }
            }
            // "The day ends when you tell it you're done." Closing can't be
            // un-done from the UI, so it asks once, plainly.
            .confirmationDialog(
                "Close out Day \(appModel.todayState?.dayIndex ?? 0)?",
                isPresented: $closeDayConfirmPresented,
                titleVisibility: .visible
            ) {
                Button("Close the day") { appModel.closeDay() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Anything you log after this counts toward tomorrow.")
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

// MARK: - Intent-error alert (failed writes must be visible)

/// Surfaces `AppModel.lastErrorMessage` as an alert, cleared on dismissal.
/// Applied twice: to the root TabView (active only while no sheet is up —
/// `isFrontmost` — so it never fights the sheet's presentation) and to the
/// presented sheet's content, which is frontmost by definition.
private struct IntentErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var appModel

    let isFrontmost: Bool

    func body(content: Content) -> some View {
        content.alert(
            "That didn't save",
            isPresented: Binding(
                get: { isFrontmost && appModel.lastErrorMessage != nil },
                set: { if !$0 { appModel.clearLastError() } }
            )
        ) {
            Button("OK", role: .cancel) { appModel.clearLastError() }
        } message: {
            Text(appModel.lastErrorMessage ?? "")
        }
    }
}

// MARK: - Yesterday sheet (retroactive one-tap logging, honestly labeled)

/// Compact "log for yesterday" sheet: the six task tiles (workout tile =
/// two slots) as one-tap buttons writing with `effectiveDate` = yesterday,
/// plus yesterday's removable pour log (corrections cut both ways). This
/// edits yesterday only — the header says so plainly.
private struct YesterdayLogSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var yesterdayDate: DayDate?
    @State private var day: DayState?

    /// The no-junk row goes client-direct (no AppModel intent yet), so a
    /// failed write can't reach the shared IntentErrorAlert; this drives the
    /// same inline "didn't save" line DayBoardNoJunkTile shows.
    @State private var noJunkSaveFailed = false

    /// Yesterday's non-revoked pours — live logs from the day itself plus
    /// any "backdated" adds made from this sheet. Yesterday stays editable
    /// until closed, and that includes taking a pour back: a fat-fingered
    /// log noticed after the cutoff (or an accidental "Met goal" tap here)
    /// is corrected by swiping it away below.
    @State private var pours: [WaterLogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.m) {
            header

            if let day {
                VStack(spacing: DromeSpacing.s) {
                    waterRow(day)
                    if !pours.isEmpty {
                        poursSection
                    }
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
                        done: day.noJunkDone,
                        title: "No junk or alcohol",
                        errorText: noJunkSaveFailed ? "That didn't save — try again" : nil,
                        buttonLabel: "Clean day"
                    ) { log { logNoJunkOk(for: $0) } }
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

    /// The shared pour ledger (PourLogList), scoped to yesterday. Removing a
    /// pour may honestly flip the water task back to not-done — the row's
    /// "Met goal" button then reappears. Retro adds show the "backdated"
    /// capsule; pours logged live during the day don't.
    private var poursSection: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("YESTERDAY'S POURS")
                .font(.system(size: 12, weight: .black))
                .tracking(1)
                .foregroundStyle(Color.dromeInk.opacity(0.45))
            PourLogList(entries: pours) { entry in
                appModel.revoke(eventUuid: entry.id)
                reload()
            }
        }
        .padding(.horizontal, DromeSpacing.m)
    }

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
        errorText: String? = nil,
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
                // Quiet inline failure line (DayBoardNoJunkTile's pattern) —
                // a failed write must never look like a dead button.
                if let errorText, !done {
                    Text(errorText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.dromeMiss)
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

    /// Runs an AppModel intent, then reloads yesterday's projection and pour
    /// log (the intent already refreshed the model's own caches).
    private func log(_ intent: (DayDate) -> Void) {
        guard let date = yesterdayDate else { return }
        intent(date)
        reload()
    }

    /// Client-direct no-junk attest (flagged for the review pass): AppModel —
    /// owned by a concurrent stage — has no logNoJunkOk intent yet, so this
    /// calls the SAME shared client and hands the result back through
    /// `noteExternalLog`, PhotoView's photoRef pattern (a retroactive log can
    /// still flip yesterday complete and must fire its completion moment).
    /// On failure the row says so inline (`noJunkSaveFailed`, matching
    /// DayBoardNoJunkTile); `lastErrorMessage` is private(set) and
    /// unreachable from here.
    private func logNoJunkOk(for date: DayDate) {
        guard let result = try? appModel.client.logNoJunkOk(effectiveDate: date) else {
            noJunkSaveFailed = true
            return
        }
        noJunkSaveFailed = false
        appModel.noteExternalLog(result)
    }

    private func load() {
        guard let today = appModel.todayState?.date,
              let date = Self.shift(today, by: -1) else { return }
        yesterdayDate = date
        reload()
    }

    private func reload() {
        guard let date = yesterdayDate else { return }
        day = try? appModel.client.dayState(date: date)
        pours = (try? appModel.client.waterLog(date: date)) ?? []
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
