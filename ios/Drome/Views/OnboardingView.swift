//
//  OnboardingView.swift
//  Drome
//
//  First-run flow: intro → setup form → (only when starting in the past) the
//  BackfillView catch-up grid. The "join mid-challenge on Day 14 in minutes" path.
//
//  Creates the challenge through the injected `DromeCoreClient` directly —
//  AppModel exposes no challenge-creation/preset/extra intents — then hands
//  past-start users to BackfillView, applies the backfill, and calls
//  `onComplete`. Integration should refresh the AppModel inside `onComplete`.
//

import SwiftUI

struct OnboardingView: View {

    // MARK: - Dependencies

    private let client: DromeCoreClient
    private let onComplete: () -> Void

    init(client: DromeCoreClient, onComplete: @escaping () -> Void) {
        self.client = client
        self.onComplete = onComplete
    }

    // MARK: - Private types

    private enum Page: Equatable {
        case intro
        case setup
        case backfill
    }

    private enum StartMode: Equatable {
        case today
        case underway
    }

    private struct PresetRow: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var oz: String
    }

    /// Shared field chrome: quiet, high-contrast, 48pt tall.
    private struct FieldChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.dromeInk)
                .padding(.horizontal, DromeSpacing.m)
                .frame(height: 48)
                .background(Color.dromeInk.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Fixed Phase 1 weekly extra preset (docs/ARCHITECTURE.md).
    private static let jobExtraId = "job_application"
    private static let jobExtraName = "Apply to a job"

    // MARK: - State

    @State private var page = Page.intro
    @State private var startMode = StartMode.today
    @State private var pastStartDate = Date()
    @State private var dietDescription = ""
    @State private var waterGoalOz = 128
    @State private var presetRows = [PresetRow(name: "24 oz bottle", oz: "24")]
    @State private var jobExtraEnabled = false
    @State private var errorMessage: String?

    @State private var createdChallenge: Challenge?
    @State private var backfillEndDate: DayDate?

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.dromeSand.ignoresSafeArea()
            switch page {
            case .intro:
                introPage.transition(.opacity)
            case .setup:
                setupPage.transition(.opacity)
            case .backfill:
                backfillPage.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .overlay(alignment: .top) {
            if let message = errorMessage {
                errorBanner(message)
            }
        }
    }

    // MARK: - Page 1: intro

    private var introPage: some View {
        VStack(spacing: DromeSpacing.l) {
            Spacer()
            Text("DROME")
                .font(.system(size: 56, weight: .black))
                .tracking(-1)
                .foregroundStyle(Color.dromeInk)
            Text("75 days is a desert.\nDrome the camel walks it with you —\none honest day at a time.")
                .font(.system(size: 17, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.dromeInk)
            Spacer()
            VStack(spacing: DromeSpacing.m) {
                Text("This program is intense — its own creator says consult a physician first.")
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.dromeInk)
                    .padding(DromeSpacing.m)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.dromeCamel.opacity(0.6), lineWidth: 1.5)
                    )
                primaryButton("Get started") { page = .setup }
                Text("Not affiliated with 75 HARD® / 44Seven Media")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }
        }
        .padding(.horizontal, DromeSpacing.l)
        .padding(.bottom, DromeSpacing.m)
    }

    // MARK: - Page 2: setup form

    private var setupPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DromeSpacing.l) {
                    Text("Set up your 75")
                        .dromeTitle()
                        .padding(.top, DromeSpacing.m)

                    section("START") {
                        Picker("Start", selection: $startMode) {
                            Text("Starting today").tag(StartMode.today)
                            Text("Already underway").tag(StartMode.underway)
                        }
                        .pickerStyle(.segmented)

                        if startMode == .underway {
                            DatePicker(
                                selection: $pastStartDate,
                                in: startDateRange,
                                displayedComponents: .date
                            ) {
                                Text("Start date")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.dromeInk)
                            }
                            .tint(Color.dromeClay)

                            let dayNumber = liveDayNumber
                            Text("You're on Day \(dayNumber)")
                                .font(.system(size: 22, weight: .black))
                                .monospacedDigit()
                                .tracking(-0.3)
                                .foregroundStyle(Color.dromeClay)
                            if dayNumber > 1 {
                                caption("You'll catch up Days 1–\(dayNumber - 1) next — it takes about a minute.")
                            }
                        }
                    }

                    section("YOUR DIET RULE") {
                        TextField("e.g. no junk, no alcohol", text: $dietDescription)
                            .modifier(FieldChrome())
                        caption("Written in your words. You check it off, you own it.")
                    }

                    section("WATER GOAL") {
                        HStack(spacing: DromeSpacing.s) {
                            TextField("128", value: $waterGoalOz, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.center)
                                .frame(width: 64)
                                .modifier(FieldChrome())
                            Text("oz per day")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.dromeInk)
                            Spacer()
                        }
                        caption("128 oz = 1 gallon, the classic goal.")
                    }

                    section("YOUR CONTAINERS") {
                        ForEach($presetRows) { $row in
                            HStack(spacing: DromeSpacing.s) {
                                TextField("Container name", text: $row.name)
                                    .modifier(FieldChrome())
                                TextField("24", text: $row.oz)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 44)
                                    .modifier(FieldChrome())
                                Text("oz")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.dromeInk.opacity(0.55))
                                Button {
                                    presetRows.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Color.dromeInk.opacity(0.4))
                                        .dromeTapTarget()
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove container")
                            }
                        }
                        Button {
                            presetRows.append(PresetRow(name: "", oz: ""))
                        } label: {
                            Label("Add container", systemImage: "plus.circle.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color.dromeClay)
                                .frame(minHeight: DromeSpacing.tapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        caption("One tap in the app logs a full container.")
                    }

                    section("WEEKLY EXTRA") {
                        Toggle(isOn: $jobExtraEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.jobExtraName)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(Color.dromeInk)
                                Text("Weekly extra: apply to one job a week")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.dromeInk.opacity(0.55))
                            }
                        }
                        .tint(Color.dromeClay)
                        .frame(minHeight: DromeSpacing.tapTarget)
                    }
                }
                .padding(.horizontal, DromeSpacing.l)
                .padding(.bottom, DromeSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: DromeSpacing.s) {
                primaryButton(continueLabel) { finishSetup() }
                Button {
                    page = .intro
                } label: {
                    Text("Back")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dromeInk.opacity(0.6))
                        .frame(minHeight: DromeSpacing.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DromeSpacing.l)
            .padding(.bottom, DromeSpacing.s)
        }
    }

    // MARK: - Page 3: backfill (past start only)

    @ViewBuilder
    private var backfillPage: some View {
        if let challenge = createdChallenge, let end = backfillEndDate {
            BackfillView(
                startDate: challenge.startDate,
                endDate: end,
                weeklyExtra: jobExtraEnabled
                    ? ExtraDef(id: Self.jobExtraId, name: Self.jobExtraName, cadence: .weekly, enabled: true)
                    : nil
            ) { days in
                do {
                    if !days.isEmpty {
                        try client.backfillDays(days)
                    }
                    onComplete()
                } catch {
                    errorMessage = message(for: error)
                }
            }
        }
    }

    // MARK: - Derived values

    /// Live "You're on Day N" for the picked past start date.
    private var liveDayNumber: Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: pastStartDate)
        let today = calendar.startOfDay(for: Date())
        let delta = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(delta, 0) + 1
    }

    /// Pickable start dates: within the current 75-day window, up to today.
    private var startDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -74, to: today) ?? today
        return earliest...Date()
    }

    private var continueLabel: String {
        if startMode == .underway, liveDayNumber > 1 {
            let count = liveDayNumber - 1
            return count == 1 ? "Continue — catch up 1 day" : "Continue — catch up \(count) days"
        }
        return "Start Day 1"
    }

    // MARK: - Actions

    private func finishSetup() {
        errorMessage = nil
        guard waterGoalOz > 0 else {
            errorMessage = "Water goal needs to be more than zero ounces."
            return
        }
        var cfg = NewChallenge()
        cfg.dietDescription = dietDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.initialWaterGoalMl = WaterUnits.ml(fromFlOz: Double(waterGoalOz))
        if startMode == .underway {
            cfg.startDate = Self.dayFormatter.string(from: pastStartDate)
        }
        do {
            let challenge = try client.createChallenge(cfg)
            try client.updatePresets(validPresets())
            // The job-application extra is a fixed Phase 1 preset def;
            // tolerate a core that hasn't seeded it.
            try? client.setExtraEnabled(id: Self.jobExtraId, enabled: jobExtraEnabled)

            createdChallenge = challenge
            let today = try client.today().date
            let end = Self.shift(today, by: -1)
            if challenge.startDate <= end {
                backfillEndDate = end
                page = .backfill
            } else {
                onComplete()
            }
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func validPresets() -> [ContainerPreset] {
        var presets: [ContainerPreset] = []
        for row in presetRows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let oz = Double(row.oz), oz > 0 else { continue }
            presets.append(ContainerPreset(
                id: UUID().uuidString,
                name: name,
                ml: WaterUnits.ml(fromFlOz: oz),
                sortOrder: presets.count
            ))
        }
        return presets
    }

    private func message(for error: Error) -> String {
        if let dromeError = error as? DromeError {
            switch dromeError {
            case .challengeAlreadyActive:
                return "A challenge is already active on this device."
            case .noActiveChallenge:
                return "No active challenge yet — set one up first."
            case .invalidDate(let detail), .invalidArgument(let detail):
                return "Check your setup: \(detail)."
            case .notFound(let detail):
                return "Missing: \(detail)."
            case .storage(let detail):
                return "Couldn't save: \(detail)."
            }
        }
        return "Something went wrong: \(error)"
    }

    // MARK: - Small builders

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DromeSpacing.s) {
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.dromeInk.opacity(0.55))
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.dromeInk.opacity(0.55))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.dromeClay, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ message: String) -> some View {
        Button {
            errorMessage = nil
        } label: {
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.dromeMiss)
                .multilineTextAlignment(.leading)
                .padding(DromeSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.dromeMiss.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DromeSpacing.l)
        .accessibilityLabel("Error: \(message). Tap to dismiss.")
        .transition(.opacity)
    }

    // MARK: - Date plumbing (calendar-date only; day-attribution stays in core)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func shift(_ date: DayDate, by days: Int) -> DayDate {
        guard let base = dayFormatter.date(from: date),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: base)
        else { return date }
        return dayFormatter.string(from: shifted)
    }
}

// MARK: - Previews

#Preview("Onboarding") {
    // NOTE: MockDromeCore is pre-seeded with an active challenge, so tapping
    // through to "create" surfaces the honest already-active error here; the
    // pages themselves are fully exercisable.
    OnboardingView(client: MockDromeCore(), onComplete: {})
}

#Preview("Onboarding — dark") {
    OnboardingView(client: MockDromeCore(), onComplete: {})
        .preferredColorScheme(.dark)
}
