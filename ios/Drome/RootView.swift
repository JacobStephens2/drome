//
//  RootView.swift
//  Drome
//
//  Minimal tab skeleton. The Today tab renders a deliberately plain task list
//  straight from TodayState to prove the mock pipeline end to end — feature
//  tiles land later from the view fan-out stage; the integration stage wires
//  them in here.
//

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        TabView {
            NavigationStack {
                TodayPlaceholderView()
                    .navigationTitle("Today")
            }
            .tabItem { Label("Today", systemImage: "sun.max") }

            NavigationStack {
                PlaceholderView(text: "History lands in a later build stage.")
                    .navigationTitle("History")
            }
            .tabItem { Label("History", systemImage: "calendar") }

            NavigationStack {
                PlaceholderView(text: "Settings land in a later build stage.")
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color.dromeClay)
        .task { appModel.refresh() }
        .alert(
            "Slow down",
            isPresented: Binding(
                get: { appModel.pendingChugWarning != nil },
                set: { if !$0 { appModel.cancelPendingWater() } }
            ),
            presenting: appModel.pendingChugWarning
        ) { _ in
            Button("Log anyway", role: .destructive) { appModel.confirmPendingWater() }
            Button("Cancel", role: .cancel) { appModel.cancelPendingWater() }
        } message: { warning in
            Text("That would be over \(warning.limitMl) ml in the last hour. Spread water through the day.")
        }
        .alert("Day complete", isPresented: $appModel.pendingCompletionMoment) {
            Button("OK") { appModel.pendingCompletionMoment = false }
        } message: {
            Text("All five tasks done. The real completion moment lands in a later stage.")
        }
    }
}

// MARK: - Today (plain proof-of-pipeline list)

private struct TodayPlaceholderView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        List {
            if let today = appModel.todayState {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Day \(today.dayIndex)")
                            .dromeCounter()
                        Text("of \(appModel.summary?.lengthDays ?? 75)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let summary = appModel.summary {
                            Text("Run \(summary.currentRun)")
                                .monospacedDigit()
                                .foregroundStyle(Color.dromeCamel)
                        }
                    }
                }

                Section("Core tasks") {
                    ForEach(CoreTask.allCases) { task in
                        taskRow(task, today: today)
                    }
                }

                if !today.weekExtras.isEmpty {
                    Section("This week") {
                        ForEach(today.weekExtras) { extra in
                            HStack {
                                statusIcon(extra.doneThisWeek)
                                Text(extra.extra.name)
                                Spacer()
                                if !extra.doneThisWeek {
                                    Button("Done") {
                                        appModel.logExtraDone(id: extra.extra.id)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                Section("Quick log (dev)") {
                    HStack(spacing: DromeSpacing.s) {
                        ForEach(appModel.presets) { preset in
                            Button(preset.name) { appModel.logWater(preset: preset) }
                                .buttonStyle(.bordered)
                                .tint(Color.dromeOasis)
                        }
                    }
                    Button("Outdoor workout, 45 min") {
                        appModel.logWorkout(durationMin: 45, outdoor: true)
                    }
                    Button("Second workout, 30 min") {
                        appModel.logWorkout(durationMin: 30, outdoor: false)
                    }
                    Button("Read 10 pages") { appModel.logReading(pages: 10) }
                    Button("Diet on plan") { appModel.logDietOk() }
                    Button("Progress photo taken") { appModel.logPhotoDone() }
                    Button("Undo last log", role: .destructive) { appModel.undoLast() }
                }
            } else {
                Section {
                    Text(appModel.lastErrorMessage ?? "Loading…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: CoreTask, today: TodayState) -> some View {
        HStack {
            statusIcon(today.day.isDone(task))
            VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                Text(task.title)
                if let detail = detail(for: task, today: today) {
                    Text(detail)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(for task: CoreTask, today: TodayState) -> String? {
        switch task {
        case .water:
            return "\(today.day.waterTotalMl) / \(today.day.waterGoalMl) ml"
        case .reading:
            return "\(today.day.pagesRead) / 10 pages"
        case .outdoorWorkout, .secondWorkout:
            let count = today.day.workouts.count
            return count == 0 ? nil : "\(count) logged"
        case .diet, .photo:
            return nil
        }
    }

    private func statusIcon(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color.dromeDone : Color.secondary)
    }
}

// MARK: - Placeholder tabs

private struct PlaceholderView: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(DromeSpacing.l)
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
