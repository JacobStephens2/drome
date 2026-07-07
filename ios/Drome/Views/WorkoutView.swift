//
//  WorkoutView.swift
//  Drome
//
//  Workout logging. Today's two slots ("Outdoor workout" / "Second workout")
//  as tap-to-toggle controls with the day board's exact semantics (tap an
//  open slot to log a default 45-minute workout, tap a checked slot to
//  revoke exactly the entry it displays — resolved by the SHARED
//  DayState.outdoorSlotEntry/.secondSlotEntry mapping, no confirmations),
//  a sub-10-second inline log form (45-minute default, prominent outdoor
//  toggle, optional note, one huge primary button), and today's logged
//  workouts with swipe-to-undo.
//
//  Flexible mode: any duration counts and order is irrelevant — an outdoor
//  workout fills the outdoor slot, any additional workout fills the second.
//  All of that logic lives in the core; this view only renders DayState.
//
//  No timers, no GPS, no HealthKit (Phase 2 — quiet footnote only).
//

import SwiftUI

struct WorkoutView: View {

    @Environment(AppModel.self) private var appModel

    @State private var durationMin = DayState.slotDefaultDurationMin
    @State private var outdoor = true
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private static let durationStepMin = 5
    private static let durationRange = 5...240

    private var day: DayState? { appModel.todayState?.day }
    private var workouts: [WorkoutEntry] { day?.workouts ?? [] }

    var body: some View {
        List {
            Group {
                header
                slotPair
                sectionLabel("LOG A WORKOUT")
                durationRow
                outdoorRow
                noteRow
                logButton
                sectionLabel("LOGGED TODAY")
                loggedSection
                footnote
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: DromeSpacing.xs,
                leading: DromeSpacing.m,
                bottom: DromeSpacing.xs,
                trailing: DromeSpacing.m
            ))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Color.dromeSand.ignoresSafeArea())
        .onAppear {
            appModel.refresh()
            resetOutdoorDefault()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("Workouts")
                .dromeTitle()
            HStack(spacing: DromeSpacing.xs) {
                if let index = appModel.todayState?.dayIndex {
                    Text("Day \(index)")
                        .monospacedDigit()
                    Text("·")
                }
                Text("Two a day. One outdoors. Any duration.")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.dromeInk.opacity(0.6))
        }
        .padding(.top, DromeSpacing.s)
    }

    // MARK: - Slot status pair (tap-to-toggle, day-board semantics)

    /// The two slots are direct check controls, exactly like the day board's
    /// workout tile: tap an open slot to log a default 45-minute workout for
    /// it (outdoor / not per slot); tap a checked slot to revoke exactly the
    /// entry that slot displays — resolved by the shared
    /// `DayState.outdoorSlotEntry` / `.secondSlotEntry` mapping, so display
    /// and revoke can never cross-wire. No confirmation either way; undo is
    /// one tap from redo. A slot done only via a backfill flag has no entry
    /// to revoke and doesn't respond.
    private var slotPair: some View {
        HStack(spacing: DromeSpacing.s) {
            SlotCard(
                title: CoreTask.outdoorWorkout.title,
                icon: "sun.max.fill",
                done: day?.outdoorWorkoutDone ?? false,
                entry: day?.outdoorSlotEntry,
                outdoor: true,
                onToggle: toggleSlot
            )
            SlotCard(
                title: CoreTask.secondWorkout.title,
                icon: "figure.run",
                done: day?.secondWorkoutDone ?? false,
                entry: day?.secondSlotEntry,
                outdoor: false,
                onToggle: toggleSlot
            )
        }
    }

    /// Day-board slot semantics: log a default 45-minute workout for an open
    /// slot; revoke the displayed entry for a checked one. Intents refresh
    /// AppModel synchronously, so the slot pair and the "logged today" list
    /// re-render from the same fresh DayState.
    private func toggleSlot(done: Bool, entry: WorkoutEntry?, outdoor: Bool) {
        withAnimation(.snappy) {
            if done {
                // Undo acts on the entry the slot displays — never a hidden
                // one. Backfill-flag-only slots (done, no entry) are disabled
                // in SlotCard and never reach here.
                guard let entry else { return }
                appModel.revoke(eventUuid: entry.id)
            } else {
                appModel.logWorkout(
                    durationMin: DayState.slotDefaultDurationMin,
                    outdoor: outdoor,
                    note: nil
                )
            }
        }
        resetOutdoorDefault()
    }

    // MARK: - Log form

    private var durationRow: some View {
        HStack(spacing: DromeSpacing.s) {
            Text("Duration")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Color.dromeInk)
            Spacer(minLength: 0)
            stepButton(
                systemName: "minus",
                accessibilityLabel: "Decrease duration",
                enabled: durationMin > Self.durationRange.lowerBound
            ) {
                durationMin = max(Self.durationRange.lowerBound, durationMin - Self.durationStepMin)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(durationMin)")
                    .font(.system(size: 28, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(Color.dromeInk)
                Text("min")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }
            .frame(minWidth: 76)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Duration \(durationMin) minutes")
            stepButton(
                systemName: "plus",
                accessibilityLabel: "Increase duration",
                enabled: durationMin < Self.durationRange.upperBound
            ) {
                durationMin = min(Self.durationRange.upperBound, durationMin + Self.durationStepMin)
            }
        }
        .padding(.vertical, DromeSpacing.s)
        .padding(.horizontal, DromeSpacing.m)
        .background(cardBackground)
    }

    private func stepButton(
        systemName: String,
        accessibilityLabel: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(enabled ? Color.dromeInk : Color.dromeInk.opacity(0.25))
                .dromeTapTarget()
                .background(Circle().fill(Color.dromeInk.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Outdoor is the trophy — the toggle is the loudest row in the form.
    private var outdoorRow: some View {
        Toggle(isOn: $outdoor) {
            HStack(spacing: DromeSpacing.m) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(outdoor ? Color.dromeCamel : Color.dromeInk.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outdoor")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.dromeInk)
                    Text(outdoor ? "Fills the outdoor slot" : "Counts toward the second slot")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dromeInk.opacity(0.55))
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Color.dromeCamel)
        .padding(DromeSpacing.m)
        .frame(minHeight: DromeSpacing.tapTarget + DromeSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(outdoor ? Color.dromeCamel.opacity(0.14) : Color.dromeInk.opacity(0.06))
        )
        .animation(.snappy(duration: 0.2), value: outdoor)
    }

    private var noteRow: some View {
        TextField("Note (optional)", text: $note)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.dromeInk)
            .focused($noteFocused)
            .submitLabel(.done)
            .padding(.horizontal, DromeSpacing.m)
            .frame(minHeight: DromeSpacing.tapTarget + DromeSpacing.s)
            .background(cardBackground)
    }

    /// The huge primary action. Defaults are right, so logging a workout is
    /// one tap from anywhere on this screen.
    private var logButton: some View {
        Button(action: submit) {
            HStack(spacing: DromeSpacing.s) {
                Image(systemName: outdoor ? "sun.max.fill" : "checkmark")
                    .font(.system(size: 18, weight: .black))
                Text(outdoor ? "Log \(durationMin) min outdoor" : "Log \(durationMin) min workout")
                    .font(.system(size: 19, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.3)
            }
            .foregroundStyle(Color.dromeSand)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.dromeClay)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, DromeSpacing.xs)
        .accessibilityHint("Logs a \(durationMin)-minute \(outdoor ? "outdoor" : "indoor") workout")
    }

    private func submit() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.snappy) {
            appModel.logWorkout(
                durationMin: durationMin,
                outdoor: outdoor,
                note: trimmed.isEmpty ? nil : trimmed
            )
        }
        note = ""
        noteFocused = false
        durationMin = DayState.slotDefaultDurationMin
        resetOutdoorDefault()
    }

    /// Smart default: while the outdoor slot is open, the next workout is
    /// probably the outdoor one; once it's filled, default to indoor.
    private func resetOutdoorDefault() {
        outdoor = !(day?.outdoorWorkoutDone ?? false)
    }

    // MARK: - Logged today

    @ViewBuilder
    private var loggedSection: some View {
        if workouts.isEmpty {
            Text("Nothing logged yet.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dromeInk.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                .background(cardBackground)
        } else {
            ForEach(workouts) { entry in
                WorkoutRowView(entry: entry)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            // Same undo primitive as the slot cards:
                            // AppModel.revoke revokes exactly this row's
                            // event and refreshes synchronously.
                            withAnimation(.snappy) {
                                appModel.revoke(eventUuid: entry.id)
                            }
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .tint(Color.dromeClay)
                    }
            }
        }
    }

    private var footnote: some View {
        Text("Watch import coming later")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.dromeInk.opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, DromeSpacing.m)
    }

    // MARK: - Shared chrome

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(Color.dromeInk.opacity(0.5))
            .padding(.top, DromeSpacing.m)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.dromeInk.opacity(0.06))
    }
}

// MARK: - Slot status card (tap-to-toggle)

/// A tappable slot check control. Tap open -> log a default 45-minute
/// workout for the slot; tap checked -> revoke the entry it displays.
/// Done-without-entry = backfilled flag: rendered done, not toggleable.
private struct SlotCard: View {
    let title: String
    let icon: String
    let done: Bool
    /// The logged entry backing this slot (shared DayState slot mapping);
    /// nil when the slot is open or satisfied only by a backfill flag.
    let entry: WorkoutEntry?
    let outdoor: Bool
    let onToggle: (_ done: Bool, _ entry: WorkoutEntry?, _ outdoor: Bool) -> Void

    var body: some View {
        Button {
            onToggle(done, entry, outdoor)
        } label: {
            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(done ? Color.dromeDone : Color.dromeInk.opacity(0.35))
                    Spacer(minLength: 0)
                    Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(done ? Color.dromeDone : Color.dromeInk.opacity(0.3))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: done)
                }
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(-0.2)
                    .foregroundStyle(Color.dromeInk)
                    .lineLimit(2, reservesSpace: true)
                // Honest states, plainly labeled — an open slot is not a
                // failure. The status line says what a tap does.
                Text(statusText)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(0.8)
                    .monospacedDigit()
                    .foregroundStyle(done ? Color.dromeDone : Color.dromeInk.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(DromeSpacing.m)
            .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(done ? Color.dromeDone.opacity(0.10) : Color.dromeInk.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(done && entry == nil)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusText: String {
        guard done else {
            // An open slot can still have a backing entry: the second slot
            // with exactly one workout logged (never the outdoor slot — its
            // entry and its done flag both mean "≥1 outdoor workout").
            // Surface it like the day board's slot row does, so the first
            // tap's log lands visibly on this card instead of re-rendering
            // "OPEN" and inviting a duplicate.
            if let entry { return "1 OF 2 · \(entry.durationMin) MIN" }
            return "OPEN · TAP TO LOG"
        }
        if let entry { return "DONE · \(entry.durationMin) MIN" }
        return "DONE"
    }

    /// States the ACTION a tap performs (log / undo), not just the state.
    private var accessibilityLabel: String {
        guard done else {
            return outdoor
                ? "Log a \(DayState.slotDefaultDurationMin) minute outdoor workout"
                : "Log a \(DayState.slotDefaultDurationMin) minute indoor or outdoor workout"
        }
        return entry != nil ? "Undo \(title.lowercased())" : "\(title) done"
    }
}

// MARK: - Logged workout row

private struct WorkoutRowView: View {
    let entry: WorkoutEntry

    var body: some View {
        HStack(alignment: .center, spacing: DromeSpacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(entry.durationMin)")
                    .font(.system(size: 24, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(Color.dromeInk)
                Text("min")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }
            .frame(minWidth: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if entry.outdoor {
                    OutdoorBadge()
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dromeInk.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DromeSpacing.m)
        .frame(minHeight: DromeSpacing.tapTarget)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.dromeInk.opacity(0.06))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = ["\(entry.durationMin) minute \(entry.outdoor ? "outdoor" : "indoor") workout"]
        if let note = entry.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: ", ")
    }
}

/// Subtle trophy badge for outdoor-logged entries.
private struct OutdoorBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 9, weight: .heavy))
            Text("OUTDOOR")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1)
        }
        .foregroundStyle(Color.dromeCamel)
        .padding(.horizontal, DromeSpacing.s)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.dromeCamel.opacity(0.16)))
    }
}

// MARK: - Previews

#Preview("Workouts") {
    WorkoutView()
        .environment(AppModel(core: MockDromeCore()))
}

#Preview("Workouts — dark") {
    WorkoutView()
        .environment(AppModel(core: MockDromeCore()))
        .preferredColorScheme(.dark)
}
