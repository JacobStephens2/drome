//
//  BackfillView.swift
//  Drome
//
//  Fast mid-challenge catch-up grid: one week per screen, seven day rows,
//  compact toggle dots for the five core tasks (the workout column carries
//  both workout slots — one dot sets outdoor + second together), plus ONE
//  weekly-extra cell per week when enabled. Tuned so 13 days take under a
//  minute: tap a row's leading check to fill the whole day, tap dots to
//  fine-tune, or use the bulk button and untick the exceptions.
//
//  Pure input UI — talks to no client; hands assembled `BackfilledDay`
//  values (water flag = met goal, not an amount) to `onDone`.
//

import SwiftUI

struct BackfillView: View {

    // MARK: - Row & entry models (private to this file)

    private struct DayInfo: Identifiable {
        let date: DayDate
        let dayIndex: Int
        /// Short human date, e.g. "Sun, Jun 21".
        let label: String
        var id: DayDate { date }
    }

    private struct DayEntry: Equatable {
        var water = false
        /// One dot = both workout slots (outdoor + second).
        var workouts = false
        var reading = false
        var diet = false
        var photo = false

        var allDone: Bool { water && workouts && reading && diet && photo }
        var anyDone: Bool { water || workouts || reading || diet || photo }

        static let complete = DayEntry(water: true, workouts: true, reading: true, diet: true, photo: true)
        static let empty = DayEntry()
    }

    private struct TaskColumn {
        let key: WritableKeyPath<DayEntry, Bool>
        let symbol: String
        let label: String
        /// The workout column renders two mini dots (two slots, one tap).
        let isDual: Bool
    }

    private static let columns: [TaskColumn] = [
        TaskColumn(key: \.water, symbol: "drop.fill", label: "Water goal", isDual: false),
        TaskColumn(key: \.workouts, symbol: "figure.run", label: "Both workouts", isDual: true),
        TaskColumn(key: \.reading, symbol: "book.fill", label: "Ten pages read", isDual: false),
        TaskColumn(key: \.diet, symbol: "fork.knife", label: "Diet", isDual: false),
        TaskColumn(key: \.photo, symbol: "camera.fill", label: "Progress photo", isDual: false),
    ]

    private static let columnWidth: CGFloat = 42
    private static let rowHeight: CGFloat = 52

    // MARK: - Inputs

    private let weeklyExtra: ExtraDef?
    private let onDone: ([BackfilledDay]) -> Void
    /// Days chunked into challenge weeks (7-day blocks by day index).
    private let weeks: [[DayInfo]]

    /// - Parameters:
    ///   - startDate: challenge start = Day 1 ("YYYY-MM-DD").
    ///   - endDate: last day to backfill, inclusive (usually yesterday).
    ///   - weeklyExtra: when non-nil, each week gets one extra cell.
    ///   - onDone: receives only days with at least one task or extra marked.
    init(
        startDate: DayDate,
        endDate: DayDate,
        weeklyExtra: ExtraDef? = nil,
        onDone: @escaping ([BackfilledDay]) -> Void
    ) {
        self.weeklyExtra = weeklyExtra
        self.onDone = onDone

        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let displayFormatter = DateFormatter()
        displayFormatter.setLocalizedDateFormatFromTemplate("EEEMMMd")

        var built: [[DayInfo]] = []
        if var cursor = dayFormatter.date(from: startDate) {
            var index = 1
            // Defensive cap at 75 — a challenge is never longer.
            while index <= 75 {
                let dateString = dayFormatter.string(from: cursor)
                if dateString > endDate { break }
                let info = DayInfo(
                    date: dateString,
                    dayIndex: index,
                    label: displayFormatter.string(from: cursor)
                )
                let week = (index - 1) / 7
                if built.count == week { built.append([]) }
                built[week].append(info)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                index += 1
            }
        }
        weeks = built
    }

    // MARK: - State

    @State private var entries: [DayDate: DayEntry] = [:]
    /// Week indices (0-based) where the weekly extra is marked done.
    @State private var extraWeeks: Set<Int> = []
    @State private var weekIndex = 0

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DromeSpacing.l)
                .padding(.top, DromeSpacing.m)
            weekBar
                .padding(.horizontal, DromeSpacing.l)
                .padding(.vertical, DromeSpacing.xs)
            columnHeader
                .padding(.horizontal, DromeSpacing.l)
            if weeks.isEmpty {
                emptyState
            } else {
                TabView(selection: $weekIndex) {
                    ForEach(weeks.indices, id: \.self) { index in
                        weekPage(index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            footer
                .padding(.horizontal, DromeSpacing.l)
                .padding(.bottom, DromeSpacing.m)
        }
        .background(Color.dromeSand.ignoresSafeArea())
    }

    // MARK: - Header & pager chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("Catch up")
                .dromeTitle()
            Text("Tap what you did. The leading check fills a whole day.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weekBar: some View {
        HStack {
            chevron("chevron.left", enabled: weekIndex > 0) { weekIndex -= 1 }
            Spacer()
            Text("Week \(weekIndex + 1) of \(max(weeks.count, 1))")
                .font(.system(size: 15, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Color.dromeInk)
            Spacer()
            chevron("chevron.right", enabled: weekIndex < weeks.count - 1) { weekIndex += 1 }
        }
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? Color.dromeClay : Color.dromeInk.opacity(0.2))
                .dromeTapTarget()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous week" : "Next week")
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Self.columns.indices, id: \.self) { index in
                let column = Self.columns[index]
                Image(systemName: column.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.5))
                    .frame(width: Self.columnWidth)
                    .accessibilityLabel(column.label)
            }
        }
    }

    // MARK: - Week page

    private func weekPage(_ index: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(weeks[index]) { day in
                dayRow(day)
            }
            if let extra = weeklyExtra {
                weekExtraRow(weekIndex: index, extra: extra)
                    .padding(.top, DromeSpacing.xs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DromeSpacing.l)
        .padding(.top, DromeSpacing.xs)
    }

    private func dayRow(_ day: DayInfo) -> some View {
        let entry = entries[day.date] ?? .empty
        return HStack(spacing: 0) {
            // Leading "day complete" control: fills / clears the whole day.
            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    entries[day.date] = entry.allDone ? .empty : .complete
                }
            } label: {
                HStack(spacing: DromeSpacing.s) {
                    Image(systemName: entry.allDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(entry.allDone ? Color.dromeDone : Color.dromeInk.opacity(0.3))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Day \(day.dayIndex)")
                            .font(.system(size: 15, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk)
                        Text(day.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.dromeInk.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Day \(day.dayIndex), \(day.label), whole day")
            .accessibilityValue(entry.allDone ? "complete" : "incomplete")

            ForEach(Self.columns.indices, id: \.self) { index in
                dotCell(day: day, column: Self.columns[index])
            }
        }
        .frame(height: Self.rowHeight)
    }

    private func dotCell(day: DayInfo, column: TaskColumn) -> some View {
        let on = (entries[day.date] ?? .empty)[keyPath: column.key]
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                entries[day.date, default: .empty][keyPath: column.key].toggle()
            }
        } label: {
            dot(on: on, dual: column.isDual)
                .frame(width: Self.columnWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(column.label), day \(day.dayIndex)")
        .accessibilityValue(on ? "done" : "not done")
    }

    @ViewBuilder
    private func dot(on: Bool, dual: Bool) -> some View {
        if dual {
            HStack(spacing: 3) {
                singleDot(on: on, size: 12)
                singleDot(on: on, size: 12)
            }
        } else {
            singleDot(on: on, size: 20)
        }
    }

    private func singleDot(on: Bool, size: CGFloat) -> some View {
        Circle()
            .strokeBorder(on ? Color.clear : Color.dromeInk.opacity(0.3), lineWidth: 2)
            .background(Circle().fill(on ? Color.dromeDone : Color.clear))
            .frame(width: size, height: size)
    }

    /// ONE cell for the whole week — weekly extras bind to the 7-day block,
    /// not a specific day, and never gate day completion.
    private func weekExtraRow(weekIndex index: Int, extra: ExtraDef) -> some View {
        let on = extraWeeks.contains(index)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                if on { extraWeeks.remove(index) } else { extraWeeks.insert(index) }
            }
        } label: {
            HStack(spacing: DromeSpacing.s) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? Color.dromeCamel : Color.dromeInk.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(extra.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.dromeInk)
                    Text("Once this week")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dromeInk.opacity(0.55))
                }
                Spacer(minLength: 0)
                singleDot(on: on, size: 20)
                    .frame(width: Self.columnWidth)
            }
            .padding(.leading, DromeSpacing.s)
            .frame(height: Self.rowHeight)
            .background(Color.dromeInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(extra.name), week \(index + 1)")
        .accessibilityValue(on ? "done" : "not done")
    }

    private var emptyState: some View {
        VStack(spacing: DromeSpacing.s) {
            Spacer()
            Text("Nothing to catch up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.dromeInk)
            Text("There are no past days in range.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dromeInk.opacity(0.55))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer (bulk + done)

    private var allDays: [DayInfo] { weeks.flatMap { $0 } }

    private var completeCount: Int {
        allDays.filter { entries[$0.date]?.allDone == true }.count
    }

    private var footer: some View {
        VStack(spacing: DromeSpacing.s) {
            Text("\(completeCount) of \(allDays.count) days complete")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.dromeInk.opacity(0.6))

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    for day in allDays { entries[day.date] = .complete }
                }
            } label: {
                Text("Mark all complete through today")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.dromeClay)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.dromeClay, lineWidth: 1.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(weeks.isEmpty)

            Button {
                onDone(assembledDays())
            } label: {
                Text(doneLabel)
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
    }

    private var doneLabel: String {
        let count = assembledDays().count
        if count == 0 { return "Skip catch-up" }
        return count == 1 ? "Save 1 day" : "Save \(count) days"
    }

    /// Only days with at least one task or extra marked are emitted; untouched
    /// days stay plain (honest) misses rather than empty backfill events. The
    /// weekly extra attaches to the first day of its week block.
    private func assembledDays() -> [BackfilledDay] {
        var result: [BackfilledDay] = []
        for (index, week) in weeks.enumerated() {
            let extraDate: DayDate? =
                (weeklyExtra != nil && extraWeeks.contains(index)) ? week.first?.date : nil
            for day in week {
                let entry = entries[day.date] ?? .empty
                var extraIds: [String] = []
                if let extra = weeklyExtra, day.date == extraDate {
                    extraIds = [extra.id]
                }
                guard entry.anyDone || !extraIds.isEmpty else { continue }
                result.append(BackfilledDay(
                    date: day.date,
                    water: entry.water,
                    outdoorWorkout: entry.workouts,
                    secondWorkout: entry.workouts,
                    reading: entry.reading,
                    diet: entry.diet,
                    photo: entry.photo,
                    extraIds: extraIds
                ))
            }
        }
        return result
    }
}

// MARK: - Previews

#Preview("Backfill — demo, Day 14") {
    BackfillView(
        startDate: "2026-06-21",
        endDate: "2026-07-03",
        weeklyExtra: ExtraDef(id: "job_application", name: "Apply to a job", cadence: .weekly, enabled: true)
    ) { days in
        print("backfilled \(days.count) days")
    }
}

#Preview("Backfill — no extra, dark") {
    BackfillView(
        startDate: "2026-06-21",
        endDate: "2026-07-03"
    ) { _ in }
        .preferredColorScheme(.dark)
}
