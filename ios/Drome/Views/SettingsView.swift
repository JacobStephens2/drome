//
//  SettingsView.swift
//  Drome
//
//  Settings: challenge facts, water goal + container presets, day rhythm,
//  extras, reading, diet, data (export & backup), and about. Mutations go
//  through the DromeCoreClient facade; after each write the injected AppModel
//  (when present in the environment) is refreshed so cached projections stay
//  current. Navigation wiring into RootView is the integration stage's job —
//  this view only needs a client.
//

import SwiftUI

// MARK: - SettingsView

@MainActor
struct SettingsView: View {

    private let client: any DromeCoreClient

    @Environment(AppModel.self) private var appModel: AppModel?
    @AppStorage("lastBackupAt") private var lastBackupAt: Double = 0

    // Loaded facts
    @State private var challenge: Challenge?
    @State private var todayDayIndex = 0
    @State private var lengthDays = 75
    @State private var showChangeStartDay = false

    // Water
    @State private var goalOz = 128
    @State private var savedGoalOz = 128
    @State private var presets: [ContainerPreset] = []

    // Day rhythm
    @State private var cutoffMinutes = 240
    @State private var savedCutoffMinutes = 240
    @State private var wakingStartMinutes = 420
    @State private var wakingEndMinutes = 1320

    // Extras / reading / diet
    @State private var extras: [ExtraDef] = []
    @State private var bookTitle = ""
    @State private var savedBookTitle = ""
    @State private var dietText = ""
    @State private var savedDietText = ""

    @State private var errorMessage: String?

    // Reset flow. The sheet only ARMS the reset (through this binding); the
    // wipe runs in onDismiss, after the sheet is fully down, so AppFlowView's
    // full-screen swap to onboarding never strands a presented sheet. The
    // sheet itself disarms on every appearance and on Cancel, so the latch
    // can never make a cancel affordance execute the wipe.
    @State private var resetSheetPresented = false
    @State private var resetArmed = false

    init(client: any DromeCoreClient) {
        self.client = client
    }

    var body: some View {
        Form {
            challengeSection
            waterSection
            cutoffSection
            wakingSection
            extrasSection
            if FeatureFlags.serverFeatures {
                accountSection
                groupsSection
            }
            readingSection
            dietSection
            dataSection
            aboutSection
            startOverSection
        }
        .tint(Color.dromeClay)
        .scrollContentBackground(.hidden)
        .background(Color.dromeSand)
        .navigationTitle("Settings")
        .task { load() }
        .onChange(of: presets) { pushPresets() }
        .onChange(of: cutoffMinutes) { saveCutoff() }
        .onChange(of: wakingStartMinutes) { saveWakingWindow() }
        .onChange(of: wakingEndMinutes) { saveWakingWindow() }
        .sheet(isPresented: $resetSheetPresented, onDismiss: performArmedReset) {
            ResetSheet(client: client, armed: $resetArmed)
        }
        .alert("Couldn't save", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var challengeSection: some View {
        Section {
            LabeledContent("Start date") {
                Text(formattedStartDate)
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk.opacity(0.75))
            }
            LabeledContent("Progress") {
                Text("Day \(todayDayIndex) of \(lengthDays)")
                    .fontWeight(.black)
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk)
            }
            Button {
                showChangeStartDay = true
            } label: {
                Label("Change start day", systemImage: "calendar.badge.clock")
                    .foregroundStyle(Color.dromeClay)
            }
            .frame(minHeight: DromeSpacing.tapTarget)
            LabeledContent("Ruleset") {
                Text(challenge?.ruleset.label ?? Ruleset.flexible.label)
                    .foregroundStyle(Color.dromeInk.opacity(0.75))
            }
            HStack {
                Text("Purist mode")
                Spacer()
                Text("Coming soon")
            }
            .foregroundStyle(Color.dromeInk.opacity(0.35))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Purist mode, coming soon")
        } header: {
            sectionHeader("Challenge")
        }
        .listRowBackground(rowBackground)
        .sheet(isPresented: $showChangeStartDay) {
            ChangeStartDaySheet(
                client: client,
                currentDayIndex: todayDayIndex,
                lengthDays: lengthDays,
                onChanged: { appModel?.refresh() }
            )
        }
    }

    private var waterSection: some View {
        Section {
            HStack(spacing: DromeSpacing.s) {
                Text("Daily goal")
                Spacer()
                TextField("oz", value: $goalOz, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .onSubmit { saveGoal() }
                Text("oz")
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                if goalOz != savedGoalOz {
                    Button("Set") { saveGoal() }
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.dromeClay)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)

            ForEach($presets) { $preset in
                ContainerPresetRow(preset: $preset)
            }
            .onDelete { presets.remove(atOffsets: $0) }
            .onMove { presets.move(fromOffsets: $0, toOffset: $1) }

            Button {
                presets.append(ContainerPreset(
                    id: UUID().uuidString,
                    name: "New container",
                    ml: WaterUnits.ml(fromFlOz: 24),
                    sortOrder: presets.count
                ))
            } label: {
                Label("Add container", systemImage: "plus")
                    .foregroundStyle(Color.dromeClay)
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Water")
        } footer: {
            Text("1 gallon = 128 oz. Goal changes apply from today — past days keep the goal they were lived under. Swipe a container to remove it.")
        }
        .listRowBackground(rowBackground)
    }

    /// Editable and forward-only: the core records the change as an event and
    /// attributes each log under the cutoff live when it was made, so past days
    /// keep the boundary they were lived under (only later logs use the new
    /// one). Saving on change is guarded against re-emitting on load.
    private var cutoffSection: some View {
        Section {
            Picker("Day cutoff", selection: $cutoffMinutes) {
                ForEach(cutoffOptions, id: \.self) { minutes in
                    Text(timeLabel(minutes)).tag(minutes)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Day rhythm")
        } footer: {
            Text("Your day rolls over at this cutoff — a late night counts toward the day you lived it. Changes apply from today; past days keep the boundary they were lived under.")
        }
        .listRowBackground(rowBackground)
    }

    private var wakingSection: some View {
        Section {
            Picker("Waking start", selection: $wakingStartMinutes) {
                ForEach(wakingStartOptions, id: \.self) { minutes in
                    Text(timeLabel(minutes)).tag(minutes)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
            Picker("Waking end", selection: $wakingEndMinutes) {
                ForEach(wakingEndOptions, id: \.self) { minutes in
                    Text(timeLabel(minutes)).tag(minutes)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } footer: {
            Text("Used for water pacing only — your goal is spread across these waking hours.")
        }
        .listRowBackground(rowBackground)
    }

    private var extrasSection: some View {
        Section {
            ForEach(extras) { extra in
                Toggle(isOn: extraBinding(extra)) {
                    VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                        Text(extra.name)
                        Text(extra.cadence == .weekly ? "Weekly" : "Daily")
                            .font(.footnote)
                            .foregroundStyle(Color.dromeInk.opacity(0.6))
                    }
                }
                .frame(minHeight: DromeSpacing.tapTarget)
            }
        } header: {
            sectionHeader("Extras")
        } footer: {
            Text("Extras never gate your day. Weekly extras get their own smaller moment.")
        }
        .listRowBackground(rowBackground)
    }

    private var readingSection: some View {
        Section {
            HStack(spacing: DromeSpacing.s) {
                TextField("Current book", text: $bookTitle)
                    .onSubmit { saveBook() }
                if bookTitle != savedBookTitle {
                    Button("Save") { saveBook() }
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.dromeClay)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Reading")
        } footer: {
            Text("Pages you log count toward the current book.")
        }
        .listRowBackground(rowBackground)
    }

    private var dietSection: some View {
        Section {
            HStack(alignment: .top, spacing: DromeSpacing.s) {
                TextField("Diet description", text: $dietText, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { saveDiet() }
                if dietText != savedDietText {
                    Button("Save") { saveDiet() }
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.dromeClay)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Diet")
        } footer: {
            Text("Your rule, in your words. Changing it doesn't rewrite past days.")
        }
        .listRowBackground(rowBackground)
    }

    private var dataSection: some View {
        Section {
            NavigationLink {
                ExportBackupView(client: client)
            } label: {
                VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                    Text("Export & backup")
                    Text(lastBackupCaption)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(backupStale ? Color.dromeMiss : Color.dromeInk.opacity(0.6))
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Data")
        }
        .listRowBackground(rowBackground)
    }

    /// Opt-in account & sync (Phase 2). Signed out, it's a quiet invitation;
    /// signed in, it shows who you are and links to the full account screen.
    private var accountSection: some View {
        Section {
            NavigationLink {
                AccountView()
            } label: {
                VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                    Text(appModel?.signedIn == true ? "Account & sync" : "Sign in to sync")
                    Text(accountCaption)
                        .font(.footnote)
                        .foregroundStyle(Color.dromeInk.opacity(0.6))
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Account")
        }
        .listRowBackground(rowBackground)
    }

    private var accountCaption: String {
        guard let appModel, appModel.signedIn else {
            return "Sync your challenge across devices and join friend groups. Free during beta."
        }
        return appModel.accountLabel ?? "Signed in"
    }

    /// Friend groups (opt-in). Signed out, it invites sign-in; signed in, it
    /// shows how many groups you're in. The screen itself handles both states.
    private var groupsSection: some View {
        Section {
            NavigationLink {
                GroupsView()
            } label: {
                VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                    Text("Groups")
                    Text(groupsCaption)
                        .font(.footnote)
                        .foregroundStyle(Color.dromeInk.opacity(0.6))
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Groups")
        }
        .listRowBackground(rowBackground)
    }

    private var groupsCaption: String {
        guard appModel?.signedIn == true else {
            return "Stay accountable with friends. Sign in to create or join a group."
        }
        let count = appModel?.myGroups.count ?? 0
        switch count {
        case 0: return "Create a group or join one by code."
        case 1: return "You're in 1 group."
        default: return "You're in \(count) groups."
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(versionString)
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk.opacity(0.75))
            }
            Text("Drome is an independent challenge tracker. It is not affiliated with, endorsed by, or connected to 75 Hard or its creators.")
                .font(.footnote)
                .foregroundStyle(Color.dromeInk.opacity(0.6))
            Text("Your data never leaves this device except when you export or share.")
                .font(.footnote)
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        } header: {
            sectionHeader("About")
        }
        .listRowBackground(rowBackground)
    }

    /// Deliberately quiet: a plain secondary section at the very bottom, not
    /// a screaming red block. The dromeMiss tint on the row is the only
    /// signal — every real warning lives in ResetSheet's two-act flow.
    private var startOverSection: some View {
        Section {
            Button {
                resetSheetPresented = true
            } label: {
                Text("Reset Drome…")
                    .foregroundStyle(Color.dromeMiss)
            }
            .frame(minHeight: DromeSpacing.tapTarget)
            .accessibilityLabel("Reset Drome")
            .accessibilityHint(
                "Opens a confirmation to erase your challenge, logged history, "
                    + "and progress photos from this phone."
            )
        } header: {
            sectionHeader("Start over")
        } footer: {
            Text("Wipes this phone's challenge, history, and photos, and returns Drome to its first screen.")
        }
        .listRowBackground(rowBackground)
    }

    // MARK: Styling helpers

    private var rowBackground: Color { Color.dromeInk.opacity(0.06) }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .black))
            .tracking(1.1)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }

    // MARK: Derived display values

    private var formattedStartDate: String {
        guard let raw = challenge?.startDate else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private var backupStale: Bool {
        lastBackupAt <= 0 || Date().timeIntervalSince1970 - lastBackupAt > 7 * 24 * 3600
    }

    private var lastBackupCaption: String {
        guard lastBackupAt > 0 else { return "Never backed up" }
        let date = Date(timeIntervalSince1970: lastBackupAt)
        return "Last backed up \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func timeLabel(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        guard let date = Calendar.current.date(from: components) else {
            return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Realistic rollover times — midnight through 6 AM, plus whatever the
    /// challenge is currently set to (in case it was created off-grid).
    private var cutoffOptions: [Int] {
        pickerOptions(stride(from: 0, through: 360, by: 60), including: cutoffMinutes)
    }

    private var wakingStartOptions: [Int] {
        pickerOptions(stride(from: 240, through: 720, by: 60), including: wakingStartMinutes)
    }

    private var wakingEndOptions: [Int] {
        pickerOptions(stride(from: 900, through: 1380, by: 60), including: wakingEndMinutes)
    }

    private func pickerOptions(_ base: StrideThrough<Int>, including current: Int) -> [Int] {
        var values = Array(base)
        if !values.contains(current) {
            values.append(current)
            values.sort()
        }
        return values
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: Load & mutations

    private func load() {
        do {
            challenge = try client.activeChallenge()
            presets = try client.containerPresets()
            extras = try client.extraDefs()
            guard let challenge else { return }

            let summary = try client.summary()
            todayDayIndex = summary.todayDayIndex
            lengthDays = summary.lengthDays

            let oz = Int(WaterUnits.flOz(fromMl: try client.waterState().goalMl).rounded())
            goalOz = oz
            savedGoalOz = oz

            savedCutoffMinutes = challenge.dayCutoffMinutes
            cutoffMinutes = challenge.dayCutoffMinutes
            wakingStartMinutes = challenge.wakingStartMinutes
            wakingEndMinutes = challenge.wakingEndMinutes
            bookTitle = challenge.currentBook
            savedBookTitle = challenge.currentBook
            dietText = challenge.dietDescription
            savedDietText = challenge.dietDescription
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    private func saveGoal() {
        guard goalOz != savedGoalOz else { return }
        guard goalOz > 0 else {
            errorMessage = "Water goal must be more than zero."
            return
        }
        do {
            try client.setWaterGoal(ml: WaterUnits.ml(fromFlOz: Double(goalOz)))
            savedGoalOz = goalOz
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    private func pushPresets() {
        var reindexed = presets
        for index in reindexed.indices {
            reindexed[index].sortOrder = index
        }
        do {
            try client.updatePresets(reindexed)
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    /// Guarded against the load-time assignment (which sets `cutoffMinutes`):
    /// only a real user change differs from `savedCutoffMinutes`, so switching
    /// tabs or reloading never emits a no-op cutoff-change event.
    private func saveCutoff() {
        guard cutoffMinutes != savedCutoffMinutes else { return }
        guard (0..<1440).contains(cutoffMinutes) else {
            errorMessage = "The day cutoff must be between midnight and 11:59 PM."
            return
        }
        do {
            try client.setDayCutoff(minutes: UInt32(cutoffMinutes))
            savedCutoffMinutes = cutoffMinutes
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    private func saveWakingWindow() {
        guard wakingStartMinutes < wakingEndMinutes else {
            errorMessage = "The waking window must start before it ends."
            return
        }
        do {
            try client.setWakingWindow(
                startMinutes: UInt16(clamping: wakingStartMinutes),
                endMinutes: UInt16(clamping: wakingEndMinutes)
            )
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    private func extraBinding(_ extra: ExtraDef) -> Binding<Bool> {
        Binding(
            get: { extras.first(where: { $0.id == extra.id })?.enabled ?? false },
            set: { enabled in
                do {
                    try client.setExtraEnabled(id: extra.id, enabled: enabled)
                    if let index = extras.firstIndex(where: { $0.id == extra.id }) {
                        extras[index].enabled = enabled
                    }
                    appModel?.refresh()
                } catch {
                    errorMessage = settingsErrorText(error)
                }
            }
        )
    }

    private func saveBook() {
        let title = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try client.setCurrentBook(title)
            bookTitle = title
            savedBookTitle = title
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    private func saveDiet() {
        do {
            try client.setDietDescription(dietText)
            savedDietText = dietText
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    /// Runs the reset the dismissed ResetSheet armed (both confirmation acts
    /// passed). By now the sheet is fully down: `resetApp()` empties the
    /// model's challenge, and AppFlowView swaps to onboarding cleanly.
    private func performArmedReset() {
        guard resetArmed else { return }
        resetArmed = false
        appModel?.resetApp()
    }
}

// MARK: - Container preset row

private struct ContainerPresetRow: View {
    @Binding var preset: ContainerPreset

    var body: some View {
        HStack(spacing: DromeSpacing.s) {
            TextField("Name", text: $preset.name)
            Spacer(minLength: DromeSpacing.s)
            TextField("oz", value: ozBinding, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 56)
            Text("oz")
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
        .frame(minHeight: DromeSpacing.tapTarget)
    }

    private var ozBinding: Binding<Int> {
        Binding(
            get: { Int(WaterUnits.flOz(fromMl: preset.ml).rounded()) },
            set: { preset.ml = WaterUnits.ml(fromFlOz: Double(max(1, $0))) }
        )
    }
}

// MARK: - Errors

private func settingsErrorText(_ error: Error) -> String {
    guard let dromeError = error as? DromeError else { return String(describing: error) }
    switch dromeError {
    case .noActiveChallenge: return "There's no active challenge on this phone."
    case .challengeAlreadyActive: return "A challenge is already active on this phone."
    case .invalidDate(let detail): return "Invalid date: \(detail)."
    case .invalidArgument(let detail): return detail
    case .notFound(let detail): return "Not found: \(detail)."
    case .taskNotRevocable(let detail): return "Nothing to un-mark: \(detail)."
    case .storage(let detail): return "Storage problem: \(detail)."
    }
}

// MARK: - Previews

#Preview("Settings") {
    let core = MockDromeCore()
    NavigationStack {
        SettingsView(client: core)
    }
    .environment(AppModel(core: core))
}

#Preview("Settings — dark") {
    let core = MockDromeCore()
    NavigationStack {
        SettingsView(client: core)
    }
    .environment(AppModel(core: core))
    .preferredColorScheme(.dark)
}
