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

// MARK: - Config-editing shim

/// Mutations the Phase-1 `DromeCoreClient` facade doesn't expose: the
/// challenge table stores `diet_description` and the day-rhythm fields, but
/// the pinned core API (docs/ARCHITECTURE.md) has no setters for them. A
/// client that can persist these declares this conformance; SettingsView
/// disables the affected editors otherwise. Integration: conform
/// LiveDromeCore (or fold these into DromeCoreClient) and the editors
/// light up on their own.
protocol DromeConfigEditing: AnyObject {
    func setDietDescription(_ text: String) throws
    /// Minutes after midnight where the day boundary sits (default 240 = 4 AM).
    func setDayCutoffMinutes(_ minutes: Int) throws
    /// Waking window (minutes after midnight); used for water pacing only.
    func setWakingWindow(startMinutes: Int, endMinutes: Int) throws
}

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

    // Water
    @State private var goalOz = 128
    @State private var savedGoalOz = 128
    @State private var presets: [ContainerPreset] = []

    // Day rhythm
    @State private var cutoffMinutes = 240
    @State private var wakingStartMinutes = 420
    @State private var wakingEndMinutes = 1320

    // Extras / reading / diet
    @State private var extras: [ExtraDef] = []
    @State private var bookTitle = ""
    @State private var savedBookTitle = ""
    @State private var dietText = ""
    @State private var savedDietText = ""

    @State private var errorMessage: String?

    init(client: any DromeCoreClient) {
        self.client = client
    }

    private var configEditor: DromeConfigEditing? { client as? DromeConfigEditing }

    var body: some View {
        Form {
            challengeSection
            waterSection
            cutoffSection
            wakingSection
            extrasSection
            readingSection
            dietSection
            dataSection
            aboutSection
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

    private var cutoffSection: some View {
        Section {
            Picker("Day cutoff", selection: $cutoffMinutes) {
                ForEach(cutoffOptions, id: \.self) { minutes in
                    Text(timeLabel(minutes)).tag(minutes)
                }
            }
            .disabled(configEditor == nil)
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Day rhythm")
        } footer: {
            Text("Your day ends when you close it or at the cutoff — late nights count toward the day you lived them."
                 + rhythmLockedNote)
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
            Text("Used for water pacing only — your goal is spread across these waking hours." + rhythmLockedNote)
        }
        .disabled(configEditor == nil)
        .listRowBackground(rowBackground)
    }

    private var rhythmLockedNote: String {
        configEditor == nil ? " (This build can't change day rhythm yet.)" : ""
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
                    .disabled(configEditor == nil)
                    .onSubmit { saveDiet() }
                if configEditor != nil, dietText != savedDietText {
                    Button("Save") { saveDiet() }
                        .font(.headline.weight(.black))
                        .foregroundStyle(Color.dromeClay)
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
        } header: {
            sectionHeader("Diet")
        } footer: {
            Text(configEditor == nil
                 ? "Set when you created your challenge — this build can't change it yet."
                 : "Your rule, in your words. Changing it doesn't rewrite past days.")
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

    private func saveCutoff() {
        guard let editor = configEditor else { return }
        do {
            try editor.setDayCutoffMinutes(cutoffMinutes)
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
    }

    private func saveWakingWindow() {
        guard let editor = configEditor else { return }
        do {
            try editor.setWakingWindow(startMinutes: wakingStartMinutes, endMinutes: wakingEndMinutes)
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
        guard let editor = configEditor else { return }
        do {
            try editor.setDietDescription(dietText)
            savedDietText = dietText
            appModel?.refresh()
        } catch {
            errorMessage = settingsErrorText(error)
        }
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
    case .storage(let detail): return "Storage problem: \(detail)."
    }
}

// MARK: - Preview support

/// Preview-support client: wraps MockDromeCore and adds the config-editing
/// and restore shims so SettingsView and ExportBackupView can be exercised
/// end-to-end standalone. Previews only — integration wires the real core
/// client, never this.
final class SettingsPreviewCore: DromeCoreClient, DromeConfigEditing, DromeSnapshotRestoring, @unchecked Sendable {

    private let base = MockDromeCore()
    private let lock = NSLock()
    private var dietOverride: String?
    private var cutoffOverride: Int?
    private var wakingStartOverride: Int?
    private var wakingEndOverride: Int?

    // MARK: DromeConfigEditing

    func setDietDescription(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        dietOverride = text
    }

    func setDayCutoffMinutes(_ minutes: Int) throws {
        guard (0..<1440).contains(minutes) else {
            throw DromeError.invalidArgument("Day cutoff must fall within the day.")
        }
        lock.lock(); defer { lock.unlock() }
        cutoffOverride = minutes
    }

    func setWakingWindow(startMinutes: Int, endMinutes: Int) throws {
        guard startMinutes < endMinutes else {
            throw DromeError.invalidArgument("The waking window must start before it ends.")
        }
        lock.lock(); defer { lock.unlock() }
        wakingStartOverride = startMinutes
        wakingEndOverride = endMinutes
    }

    // MARK: DromeSnapshotRestoring
    //
    // The mock always has an active challenge, so restore reports exactly
    // what the core would: snapshots only import into a fresh store.

    func importJson(_ snapshot: String) throws {
        let data = Data(snapshot.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw DromeError.invalidArgument("That file isn't a Drome backup.")
        }
        throw DromeError.challengeAlreadyActive
    }

    // MARK: DromeCoreClient (forwarded, with config overlays)

    func activeChallenge() throws -> Challenge? {
        guard var challenge = try base.activeChallenge() else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let dietOverride { challenge.dietDescription = dietOverride }
        if let cutoffOverride { challenge.dayCutoffMinutes = cutoffOverride }
        if let wakingStartOverride { challenge.wakingStartMinutes = wakingStartOverride }
        if let wakingEndOverride { challenge.wakingEndMinutes = wakingEndOverride }
        return challenge
    }

    @discardableResult
    func createChallenge(_ cfg: NewChallenge) throws -> Challenge {
        try base.createChallenge(cfg)
    }

    func containerPresets() throws -> [ContainerPreset] {
        try base.containerPresets()
    }

    func updatePresets(_ presets: [ContainerPreset]) throws {
        try base.updatePresets(presets)
    }

    func extraDefs() throws -> [ExtraDef] {
        try base.extraDefs()
    }

    func setExtraEnabled(id: String, enabled: Bool) throws {
        try base.setExtraEnabled(id: id, enabled: enabled)
    }

    func setCurrentBook(_ title: String) throws {
        try base.setCurrentBook(title)
    }

    func setWaterGoal(ml: Int64) throws {
        try base.setWaterGoal(ml: ml)
    }

    func logWater(ml: Int64, effectiveDate: DayDate?) throws -> LogResult {
        try base.logWater(ml: ml, effectiveDate: effectiveDate)
    }

    func logWorkout(durationMin: Int, outdoor: Bool, note: String?, effectiveDate: DayDate?) throws -> LogResult {
        try base.logWorkout(durationMin: durationMin, outdoor: outdoor, note: note, effectiveDate: effectiveDate)
    }

    func logReading(bookTitle: String, pages: Int, effectiveDate: DayDate?) throws -> LogResult {
        try base.logReading(bookTitle: bookTitle, pages: pages, effectiveDate: effectiveDate)
    }

    func logDietOk(effectiveDate: DayDate?) throws -> LogResult {
        try base.logDietOk(effectiveDate: effectiveDate)
    }

    func logPhotoDone(photoRef: String?, effectiveDate: DayDate?) throws -> LogResult {
        try base.logPhotoDone(photoRef: photoRef, effectiveDate: effectiveDate)
    }

    func logExtraDone(extraId: String, effectiveDate: DayDate?) throws -> LogResult {
        try base.logExtraDone(extraId: extraId, effectiveDate: effectiveDate)
    }

    @discardableResult
    func closeDay(date: DayDate) throws -> DayState {
        try base.closeDay(date: date)
    }

    func revokeEvent(eventUuid: String) throws {
        try base.revokeEvent(eventUuid: eventUuid)
    }

    func backfillDays(_ days: [BackfilledDay]) throws {
        try base.backfillDays(days)
    }

    func dayState(date: DayDate) throws -> DayState {
        try base.dayState(date: date)
    }

    func today() throws -> TodayState {
        try base.today()
    }

    func summary() throws -> ChallengeSummary {
        try base.summary()
    }

    func calendar(from: DayDate, to: DayDate) throws -> [DayBrief] {
        try base.calendar(from: from, to: to)
    }

    func waterState() throws -> WaterState {
        try base.waterState()
    }

    func checkChug(addMl: Int64) throws -> ChugCheck {
        try base.checkChug(addMl: addMl)
    }

    func shareCard(date: DayDate) throws -> ShareCardData {
        try base.shareCard(date: date)
    }

    func exportJson() throws -> String {
        try base.exportJson()
    }

    func exportCsv() throws -> String {
        try base.exportCsv()
    }
}

// MARK: - Previews

#Preview("Settings") {
    let core = SettingsPreviewCore()
    NavigationStack {
        SettingsView(client: core)
    }
    .environment(AppModel(core: core))
}

#Preview("Settings — dark") {
    let core = SettingsPreviewCore()
    NavigationStack {
        SettingsView(client: core)
    }
    .environment(AppModel(core: core))
    .preferredColorScheme(.dark)
}
