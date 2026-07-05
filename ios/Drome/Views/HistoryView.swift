//
//  HistoryView.swift
//  Drome
//
//  History tab: every day from challenge start through today, as a plain
//  honest list — Day N, date, complete / not complete, and a BACKFILLED tag
//  where it applies. No streak theatrics, no shame styling: an incomplete
//  day is a quiet "—", not a red mark. Tapping a day opens its ShareCardSheet.
//
//  Data comes straight from `client.calendar` (the SAME client instance
//  backing AppModel). DesignSystem tokens only.
//

import SwiftUI

struct HistoryView: View {
    private let client: any DromeCoreClient

    @State private var briefs: [DayBrief] = []
    @State private var todayDate: DayDate?
    @State private var selected: DayBrief?
    @State private var loadFailed = false

    init(client: any DromeCoreClient) {
        self.client = client
    }

    var body: some View {
        Group {
            if briefs.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(briefs) { brief in
                            Button {
                                selected = brief
                            } label: {
                                row(brief)
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowBackground(Color.dromeInk.opacity(0.06))
                    } footer: {
                        Text("\(completeCount) of \(briefs.count) days complete so far. Tap a day for its share card.")
                            .monospacedDigit()
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.dromeSand.ignoresSafeArea())
        .navigationTitle("History")
        .onAppear(perform: load)
        .sheet(item: $selected) { brief in
            if let data = try? client.shareCard(date: brief.date) {
                ShareCardSheet(data: data)
            } else {
                Text("Couldn't load that day.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                    .padding(DromeSpacing.l)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Row

    private func row(_ brief: DayBrief) -> some View {
        HStack(spacing: DromeSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DromeSpacing.s) {
                    Text("Day \(brief.dayIndex)")
                        .font(.system(size: 16, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeInk)
                    if brief.date == todayDate {
                        Text("TODAY")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1.2)
                            .foregroundStyle(Color.dromeClay)
                    }
                }
                Text(Self.displayDate(brief.date))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }

            Spacer(minLength: 0)

            if brief.isBackfilled {
                Text("BACKFILLED")
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.dromeInk.opacity(0.3), lineWidth: 1)
                    )
            }

            if brief.coreComplete {
                HStack(spacing: DromeSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Complete")
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.dromeDone)
            } else {
                Text("—")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.dromeInk.opacity(0.4))
                    .accessibilityLabel("Not complete")
            }
        }
        .frame(minHeight: DromeSpacing.tapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DromeSpacing.s) {
            Text(loadFailed ? "Couldn't load your history" : "No days yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.dromeInk)
            Text(loadFailed
                 ? "Pull the app down and back up, or relaunch."
                 : "Your days will show up here as you live them.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.dromeInk.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var completeCount: Int {
        briefs.filter(\.coreComplete).count
    }

    private func load() {
        loadFailed = false
        do {
            guard let challenge = try client.activeChallenge() else {
                briefs = []
                return
            }
            let today = try client.today().date
            todayDate = today
            guard challenge.startDate <= today else {
                briefs = []
                return
            }
            briefs = try client.calendar(from: challenge.startDate, to: today)
        } catch {
            briefs = []
            loadFailed = true
        }
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
        return parsed.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Previews

#Preview("History (demo fixture)") {
    let core = MockDromeCore()
    return NavigationStack {
        HistoryView(client: core)
    }
    .environment(AppModel(core: core))
}

#Preview("History — dark") {
    let core = MockDromeCore()
    return NavigationStack {
        HistoryView(client: core)
    }
    .environment(AppModel(core: core))
    .preferredColorScheme(.dark)
}
