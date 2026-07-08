//
//  DayEditSheet.swift
//  Drome
//
//  Per-day editor for any challenge day — the six task tiles (workout tile =
//  two slots) as one-tap buttons writing with `effectiveDate` = this day, plus
//  the day's removable pour log (corrections cut both ways). Done rows toggle
//  off too: an "Un-mark" appears whenever the day's `DayState.revocable` (or a
//  live workout slot entry) says a live event backs the done — backfill-flag
//  days render done, not tappable-off.
//
//  The core has no editable-window guard: an explicit effective date always
//  wins (time::attribute_date step 1), so this edits any prior day — a closed
//  Day 23 while you're on Day 25 included — not just yesterday. The board's
//  "log for yesterday" affordance and History's tap-a-day both present this,
//  pointed at their date. A "Share this day" button keeps the read-only card
//  one tap away (History used to open it directly).
//

import SwiftUI

struct DayEditSheet: View {
    @Environment(AppModel.self) private var appModel

    /// The calendar date this sheet edits ("YYYY-MM-DD").
    let date: DayDate

    @State private var day: DayState?

    /// This day's non-revoked pours — live logs from the day itself plus any
    /// "backdated" adds made from this sheet. A day stays editable regardless
    /// of close, and that includes taking a pour back: a fat-fingered log (or
    /// an accidental "Met goal" tap here) is corrected by swiping it away.
    @State private var pours: [WaterLogEntry] = []

    /// Read-only share card for this day, presented over the editor.
    @State private var sharePayload: SharePayload?

    /// Identifiable wrapper so the share card presents via `.sheet(item:)`
    /// (ShareCardData itself is only Hashable).
    private struct SharePayload: Identifiable {
        let data: ShareCardData
        var id: DayDate { data.date }
    }

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
                        buttonLabel: "Log 45 min",
                        // Un-marking revokes exactly the entry the shared slot
                        // mapping displays (Models.swift) — never a hidden one.
                        // Flag-only (backfilled) slots have no entry and render
                        // plain done.
                        unmark: unmarkAction(for: day.outdoorSlotEntry)
                    ) { log { appModel.logWorkout(durationMin: 45, outdoor: true, effectiveDate: $0) } }
                    taskRow(
                        done: day.secondWorkoutDone,
                        title: "Indoor or Outdoor",
                        buttonLabel: "Log 30 min",
                        unmark: unmarkAction(for: day.secondSlotEntry)
                    ) { log { appModel.logWorkout(durationMin: 30, outdoor: false, effectiveDate: $0) } }
                    taskRow(
                        done: day.readingDone,
                        title: "Reading",
                        detail: "\(day.pagesRead) of 10 pages",
                        buttonLabel: "+10 pages",
                        // Peels the newest entry; the row may honestly stay done
                        // until enough entries are peeled — so the label
                        // promises an entry undo (matching ReadingView), never a
                        // full un-mark.
                        unmark: day.revocable.reading ? { unmark(.reading) } : nil,
                        unmarkLabel: "Undo last entry",
                        unmarkAccessibilityLabel: "Undo this day's last reading entry"
                    ) { log { appModel.logReading(pages: 10, effectiveDate: $0) } }
                    taskRow(
                        done: day.dietDone,
                        title: "Diet",
                        buttonLabel: "Kept it",
                        unmark: day.revocable.diet ? { unmark(.diet) } : nil
                    ) { log { appModel.logDietOk(effectiveDate: $0) } }
                    taskRow(
                        done: day.noJunkDone,
                        title: "No junk or alcohol",
                        buttonLabel: "Clean day",
                        unmark: day.revocable.noJunk ? { unmark(.noJunk) } : nil
                    ) { log { appModel.logNoJunkOk(effectiveDate: $0) } }
                    taskRow(
                        done: day.photoDone,
                        title: "Progress photo",
                        buttonLabel: "Taken",
                        unmark: day.revocable.photo ? { unmark(.photo) } : nil
                    ) { log { appModel.logPhotoDone(effectiveDate: $0) } }
                }
            } else {
                Text("Couldn't load that day.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }

            Spacer(minLength: 0)
        }
        .padding(DromeSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.dromeSand.ignoresSafeArea())
        .presentationDetents([.large])
        .onAppear(perform: reload)
        .sheet(item: $sharePayload) { payload in
            ShareCardSheet(data: payload.data)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("EDITING")
                    .font(.system(size: 12, weight: .black))
                    .tracking(1.4)
                    .foregroundStyle(Color.dromeClay)
                Spacer(minLength: 0)
                Button {
                    if let data = try? appModel.client.shareCard(date: date) {
                        sharePayload = SharePayload(data: data)
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.dromeInk.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share this day's card")
            }
            if let day {
                Text("Day \(day.dayIndex) — \(Self.displayDate(day.date))")
                    .font(.system(size: 22, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.3)
                    .foregroundStyle(Color.dromeInk)
            }
            Text("Log or un-mark anything for this day — it counts toward this day, not today.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
    }

    // MARK: Rows

    /// The shared pour ledger (PourLogList), scoped to this day. Removing a
    /// pour may honestly flip the water task back to not-done — the row's "Met
    /// goal" button then reappears. Retro adds show the "backdated" capsule;
    /// pours logged live during the day don't.
    private var poursSection: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("THIS DAY'S POURS")
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
        buttonLabel: String,
        /// Non-nil exactly when a live event backs the done (this day's
        /// `DayState.revocable`, or a displayed workout slot entry) — the row
        /// then toggles off. Nil + done = backfilled flag: renders done, not
        /// tappable-off.
        unmark: (() -> Void)? = nil,
        /// Visible label for the unmark control. The default suits the attest
        /// tasks, whose revoke genuinely un-marks; a task whose revoke only
        /// peels one entry (reading) MUST say so instead.
        unmarkLabel: String = "Un-mark",
        unmarkAccessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DromeSpacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(done ? Color.dromeDone : Color.dromeInk.opacity(0.3))
                .contentTransition(.symbolEffect(.replace))
                .animation(.spring(response: 0.3, dampingFraction: 0.55), value: done)
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
                if let unmark {
                    // A plain correction — same quiet weight as the log button,
                    // no confirmation (re-logging is one tap away).
                    Button(action: unmark) {
                        Text(unmarkLabel)
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.dromeInk.opacity(0.7))
                            .padding(.horizontal, DromeSpacing.m)
                            .frame(minHeight: DromeSpacing.tapTarget)
                            .background(Capsule().strokeBorder(Color.dromeInk.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        unmarkAccessibilityLabel ?? "Un-mark \(title.lowercased()), for this day"
                    )
                } else {
                    Text("Done")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.dromeDone)
                }
            } else {
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
                .accessibilityLabel("\(buttonLabel), for this day")
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

    /// Runs an AppModel intent for this day, then reloads its projection and
    /// pour log (the intent already refreshed the model's own caches).
    private func log(_ intent: (DayDate) -> Void) {
        intent(date)
        reload()
    }

    /// Toggles a task off for this day (revokes its newest live event).
    private func unmark(_ kind: RevocableTask) {
        appModel.revokeTask(kind, date: date)
        reload()
    }

    /// Un-mark action for a workout slot: revokes exactly the entry the shared
    /// slot mapping displays, or nil when nothing live backs the slot
    /// (unfilled, or a backfill flag).
    private func unmarkAction(for entry: WorkoutEntry?) -> (() -> Void)? {
        guard let entry else { return nil }
        return {
            appModel.revoke(eventUuid: entry.id)
            reload()
        }
    }

    private func reload() {
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

    private static func displayDate(_ date: DayDate) -> String {
        guard let parsed = dayFormatter.date(from: date) else { return date }
        return parsed.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

// MARK: - Preview

#Preview("Edit a day") {
    let core = MockDromeCore()
    return Color.dromeSand
        .sheet(isPresented: .constant(true)) {
            DayEditSheet(date: (try? core.today().date) ?? "2026-07-03")
                .environment(AppModel(core: core))
        }
}
