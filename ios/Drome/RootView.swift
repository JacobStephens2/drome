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
        case today, history, groups, settings
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

            // A dedicated Groups tab appears ONLY while you're in at least one
            // group (specs.md, Groups) — otherwise groups live under Settings.
            if !appModel.myGroups.isEmpty {
                NavigationStack {
                    GroupsView()
                }
                .tabItem { Label("Groups", systemImage: "person.3") }
                .tag(Tab.groups)
            }

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
            if FeatureFlags.serverFeatures {
                // Opportunistic sync on launch (no-op when signed out).
                appModel.pokeSync()
                // Refresh groups and pull any pending nudges (no-op signed out).
                appModel.refreshGroupsAndNudges()
            }
        }
        // Widget logs and day rollovers happen while the app is backgrounded;
        // re-project on every return to foreground so the board is never stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appModel.refresh()
                if FeatureFlags.serverFeatures {
                    appModel.pokeSync()
                    // Keep the Account "Plan" row from drifting from the server
                    // between launches (no-op when signed out).
                    appModel.refreshEntitlementSnapshot()
                    // Fresh groups + nudge check on every return to foreground.
                    appModel.refreshGroupsAndNudges()
                }
            }
        }
        // Leaving your last group removes the Groups tab; if it was selected,
        // fall back to Today so the selection can't point at a gone tab.
        .onChange(of: appModel.myGroups.isEmpty) { _, isEmpty in
            if isEmpty && tab == .groups {
                tab = .today
            }
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
        // A one-active-challenge conflict silently swapped the board to the
        // account's existing challenge; explain it here on the primary surface
        // (the Account-screen banner alone is easy to miss).
        .alert(
            "Your challenge changed",
            isPresented: $appModel.boardConflictNotice
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your account already had an active challenge, so this phone adopted it. Nothing was lost — the challenge that was on this phone is archived, with its days kept.")
        }
        // Failed writes must never look like successful taps: any intent
        // error lands here as an honest alert. Yields to a presented sheet,
        // whose content carries its own copy of the same alert.
        .modifier(IntentErrorAlert(isFrontmost: sheet == nil))
        // A received nudge appears as a quiet, dismissible banner over the app
        // (one at a time). Gentle by design — a wave, never a shaming poke.
        .overlay(alignment: .top) { nudgeBanner }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appModel.receivedNudges)
    }

    // MARK: - Received-nudge banner (quiet, non-shaming; dismiss marks seen)

    @ViewBuilder
    private var nudgeBanner: some View {
        // Never draw over a celebration moment. This banner is added LATER in the
        // modifier chain than the weekly-moment overlay, so it wins z-order and
        // would otherwise cover the full-screen weekly scrim (and the same
        // after-sync fetch that populates nudges can fire while a moment is up).
        // Suppress while any moment is pending — the moment comes first.
        if appModel.pendingWeeklyMoment == nil,
           appModel.pendingCompletionMoment == nil,
           let nudge = appModel.receivedNudges.first {
            NudgeBanner(nudge: nudge) { appModel.dismissNudge(nudge) }
                .padding(.horizontal, DromeSpacing.m)
                .transition(.move(edge: .top).combined(with: .opacity))
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
            WorkoutView()
        case .reading:
            ReadingView(client: appModel.client)
        case .photo:
            PhotoView(client: appModel.client)
        case .yesterday:
            // The board only offers this while yesterday is open, but the
            // editor itself works on any day (DayEditSheet).
            if let yesterday = yesterdayDate() {
                DayEditSheet(date: yesterday)
            } else {
                Text("Couldn't load yesterday.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                    .padding(DromeSpacing.l)
            }
        case .share(let data):
            ShareCardSheet(data: data)
        }
    }

    /// Yesterday's calendar date ("YYYY-MM-DD"), for the board's "log for
    /// yesterday" affordance. Display-only date math; attribution stays in core.
    private func yesterdayDate() -> DayDate? {
        guard let today = appModel.todayState?.date,
              let base = Self.dayFormatter.date(from: today),
              let shifted = Calendar.current.date(byAdding: .day, value: -1, to: base)
        else { return nil }
        return Self.dayFormatter.string(from: shifted)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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

// MARK: - Received-nudge banner

/// A gentle, dismissible "someone nudged you" banner. Deliberately warm and
/// non-shaming — it names the friend and the group, nothing about what you
/// have or haven't done. Dismissing clears it (the server already marked it
/// seen when it delivered it).
private struct NudgeBanner: View {
    let nudge: ReceivedNudge
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DromeSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(nudge.fromDisplayName) nudged you 👋")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.dromeInk)
                Text("in \(nudge.groupName)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                    .frame(width: DromeSpacing.tapTarget, height: DromeSpacing.tapTarget)
            }
            .accessibilityLabel("Dismiss nudge")
        }
        .padding(.leading, DromeSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.dromeCamel.opacity(0.18))
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
        )
        .accessibilityElement(children: .combine)
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
