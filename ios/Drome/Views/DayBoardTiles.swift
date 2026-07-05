//
//  DayBoardTiles.swift
//  Drome
//
//  Tile components for DayBoardView. Each of the six core tiles shows its
//  task's REAL data shape (oz vs goal, two tappable workout slots, pages +
//  book, named diet, no-junk attest, photo check) — deliberately NOT
//  identical checkboxes. Completed tiles read as decisively DONE (dromeDone);
//  open tiles say exactly what's left. Tiles are dumb: state in, closures
//  out. DayBoardView wires them to AppModel intents and navigation callbacks.
//

import SwiftUI

// MARK: - Shared formatting

enum DayBoardFormat {
    /// Flexible-mode reading requirement (pages sum >= 10, per ARCHITECTURE).
    static let readingGoalPages = 10

    static func oz(_ ml: Int64) -> Int {
        Int(WaterUnits.flOz(fromMl: ml).rounded())
    }

    /// Rounds up so an unfinished goal never displays "0 oz left".
    static func ozLeft(total: Int64, goal: Int64) -> Int {
        max(0, Int(WaterUnits.flOz(fromMl: max(0, goal - total)).rounded(.up)))
    }

    static func pagesLeftLabel(_ pagesRead: Int) -> String {
        let left = max(0, readingGoalPages - pagesRead)
        return left == 1 ? "1 page" : "\(left) pages"
    }
}

// MARK: - Tile chrome

/// Shared card chrome. Done tiles get the decisive dromeDone wash + border;
/// open tiles stay quiet ink-on-sand. `secondary` (weekly extras) is visibly
/// subordinate: tighter padding, outline only, never the done wash.
struct DayBoardTileChrome<Content: View>: View {
    var done: Bool
    var secondary: Bool
    private let content: Content

    init(done: Bool, secondary: Bool = false, @ViewBuilder content: () -> Content) {
        self.done = done
        self.secondary = secondary
        self.content = content()
    }

    var body: some View {
        content
            .padding(secondary ? DromeSpacing.s + DromeSpacing.xs : DromeSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        done && !secondary
                            ? Color.dromeDone.opacity(0.14)
                            : Color.dromeInk.opacity(secondary ? 0 : 0.05)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        done && !secondary
                            ? Color.dromeDone.opacity(0.55)
                            : Color.dromeInk.opacity(secondary ? 0.18 : 0.12),
                        lineWidth: 1
                    )
            )
    }
}

/// Tracked-caps title row with a trailing DONE badge (or chevron when the
/// tile navigates somewhere and is still open).
struct DayBoardTileHeader: View {
    var icon: String
    var title: String
    var tint: Color
    var done: Bool
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: DromeSpacing.s) {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(done ? Color.dromeDone : tint)
            Text(title)
                .font(.caption.weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(Color.dromeInk.opacity(0.65))
            Spacer(minLength: 0)
            if done {
                HStack(spacing: DromeSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("DONE").tracking(1.2)
                }
                .font(.caption.weight(.black))
                .foregroundStyle(Color.dromeDone)
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.dromeInk.opacity(0.35))
            }
        }
    }
}

// MARK: - Water

struct DayBoardWaterTile: View {
    var day: DayState
    var onOpen: () -> Void

    private var fraction: Double {
        guard day.waterGoalMl > 0 else { return 0 }
        return min(1, max(0, Double(day.waterTotalMl) / Double(day.waterGoalMl)))
    }

    var body: some View {
        Button(action: onOpen) {
            DayBoardTileChrome(done: day.waterDone) {
                VStack(alignment: .leading, spacing: DromeSpacing.s) {
                    DayBoardTileHeader(
                        icon: "drop.fill", title: "WATER", tint: .dromeOasis,
                        done: day.waterDone, showsChevron: true
                    )
                    HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.xs) {
                        Text("\(DayBoardFormat.oz(day.waterTotalMl))")
                            .font(.title2.weight(.black))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk)
                        Text("/ \(DayBoardFormat.oz(day.waterGoalMl)) oz")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk.opacity(0.55))
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.dromeInk.opacity(0.1))
                            if fraction > 0 {
                                Capsule()
                                    .fill(day.waterDone ? Color.dromeDone : Color.dromeOasis)
                                    .frame(width: max(6, geo.size.width * fraction))
                            }
                        }
                    }
                    .frame(height: 6)
                    Text(day.waterDone
                         ? "Goal met"
                         : "\(DayBoardFormat.ozLeft(total: day.waterTotalMl, goal: day.waterGoalMl)) oz left")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(day.waterDone ? Color.dromeDone : Color.dromeInk.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.waterDone
            ? "Water done, \(DayBoardFormat.oz(day.waterTotalMl)) of \(DayBoardFormat.oz(day.waterGoalMl)) ounces"
            : "Water, \(DayBoardFormat.oz(day.waterTotalMl)) of \(DayBoardFormat.oz(day.waterGoalMl)) ounces, \(DayBoardFormat.ozLeft(total: day.waterTotalMl, goal: day.waterGoalMl)) ounces left")
    }
}

// MARK: - Workouts (two tappable slots)

/// The two slot rows are direct check controls: tap an unchecked slot to log
/// a default 45-minute workout for it (outdoor / not per slot), tap a checked
/// slot to revoke exactly the entry that row displays — no confirmation
/// either way, undo is one tap away from redo. The header row (with its
/// chevron) still opens WorkoutView for durations and notes. A slot backed
/// only by a backfill flag has no entry to revoke and doesn't respond.
struct DayBoardWorkoutsTile: View {
    var day: DayState
    var onOpen: () -> Void
    /// Log a default 45-minute workout for a slot (`outdoor` per slot).
    var onLogSlot: (_ outdoor: Bool) -> Void
    /// Revoke the workout entry backing a tapped checked slot.
    var onUndoEntry: (WorkoutEntry) -> Void

    private var bothDone: Bool { day.outdoorWorkoutDone && day.secondWorkoutDone }

    // Slot -> entry resolution lives in the SHARED DayState.outdoorSlotEntry /
    // .secondSlotEntry extension (DromeShared/Models.swift) — one mapping used
    // by display and undo here AND by WorkoutView's slot rows, so a tap always
    // revokes exactly the entry the row shows. After revoking a displayed
    // outdoor entry the check may legitimately stay on — another outdoor
    // workout then backs the slot and the row shows that survivor.

    var body: some View {
        DayBoardTileChrome(done: bothDone) {
            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                Button(action: onOpen) {
                    DayBoardTileHeader(
                        icon: "figure.run", title: "WORKOUTS", tint: .dromeClay,
                        done: bothDone, showsChevron: true
                    )
                    .frame(minHeight: DromeSpacing.tapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workouts, open durations and notes")
                slotRow(
                    label: "Outdoor", done: day.outdoorWorkoutDone,
                    entry: day.outdoorSlotEntry, outdoor: true
                )
                slotRow(
                    label: "Second", done: day.secondWorkoutDone,
                    entry: day.secondSlotEntry, outdoor: false
                )
            }
        }
    }

    private func slotRow(
        label: String,
        done: Bool,
        entry: WorkoutEntry?,
        outdoor: Bool
    ) -> some View {
        Button {
            if done {
                // Undo acts on the entry this row displays — never a hidden
                // one. A slot done only via a backfill flag has no entry and
                // is disabled below.
                if let entry { onUndoEntry(entry) }
            } else {
                onLogSlot(outdoor)
            }
        } label: {
            HStack(spacing: DromeSpacing.s) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(done ? Color.dromeDone : Color.dromeInk.opacity(0.3))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: done)
                Text(label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.dromeInk)
                Spacer(minLength: 0)
                if let entry {
                    HStack(spacing: DromeSpacing.xs) {
                        if let note = entry.note, !note.isEmpty {
                            Text(note)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.dromeInk.opacity(0.5))
                                .lineLimit(1)
                        }
                        Text("\(entry.durationMin) min")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk.opacity(0.75))
                    }
                } else if done {
                    // Done without an entry = backfilled flag (nothing to undo).
                    Text("Done")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.dromeDone)
                } else {
                    Text("tap to log \(DayState.slotDefaultDurationMin) min")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeInk.opacity(0.5))
                }
            }
            .frame(minHeight: DromeSpacing.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done && entry == nil)
        .accessibilityLabel(slotAccessibilityLabel(
            label: label, done: done, outdoor: outdoor, canUndo: entry != nil
        ))
    }

    /// States the ACTION a tap performs (log / undo), not just the state.
    private func slotAccessibilityLabel(
        label: String, done: Bool, outdoor: Bool, canUndo: Bool
    ) -> String {
        guard done else {
            return outdoor
                ? "Log a \(DayState.slotDefaultDurationMin) minute outdoor workout"
                : "Log a \(DayState.slotDefaultDurationMin) minute second workout"
        }
        return canUndo ? "Undo \(label.lowercased()) workout" : "\(label) workout done"
    }
}

// MARK: - Reading

struct DayBoardReadingTile: View {
    var day: DayState
    var book: String
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            DayBoardTileChrome(done: day.readingDone) {
                VStack(alignment: .leading, spacing: DromeSpacing.s) {
                    DayBoardTileHeader(
                        icon: "book.fill", title: "READING", tint: .dromeCamel,
                        done: day.readingDone, showsChevron: true
                    )
                    HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.xs) {
                        Text("\(day.pagesRead)")
                            .font(.title2.weight(.black))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk)
                        Text("/ \(DayBoardFormat.readingGoalPages) pages")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk.opacity(0.55))
                    }
                    HStack(spacing: DromeSpacing.xs) {
                        if !day.readingDone {
                            Text("\(DayBoardFormat.pagesLeftLabel(day.pagesRead)) left")
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.dromeInk.opacity(0.7))
                            Text("·")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.dromeInk.opacity(0.4))
                        }
                        Text(book.isEmpty ? "No current book set" : book)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.dromeInk.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.readingDone
            ? "Reading done, \(day.pagesRead) pages"
            : "Reading, \(day.pagesRead) of \(DayBoardFormat.readingGoalPages) pages, \(DayBoardFormat.pagesLeftLabel(day.pagesRead)) left")
    }
}

// MARK: - Diet (inline attest with a small confirm)

struct DayBoardDietTile: View {
    var dietDescription: String
    var done: Bool
    var onAttest: () -> Void

    @State private var confirming = false

    var body: some View {
        DayBoardTileChrome(done: done) {
            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                DayBoardTileHeader(icon: "fork.knife", title: "DIET", tint: .dromeCamel, done: done)
                HStack(spacing: DromeSpacing.m) {
                    VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                        Text(dietDescription.isEmpty ? "Your diet" : dietDescription)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.dromeInk)
                            .lineLimit(2)
                        if !done {
                            Text("Attest for today")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.dromeInk.opacity(0.55))
                        }
                    }
                    Spacer(minLength: 0)
                    if !done {
                        Button {
                            confirming = true
                        } label: {
                            Text("I kept it")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.dromeSand)
                                .padding(.horizontal, DromeSpacing.m)
                                .frame(minHeight: DromeSpacing.tapTarget)
                                .background(Capsule().fill(Color.dromeClay))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Attest diet kept today")
                        .confirmationDialog(
                            "Diet kept today?",
                            isPresented: $confirming,
                            titleVisibility: .visible
                        ) {
                            Button("Yes — I kept my diet") { onAttest() }
                            Button("Not yet", role: .cancel) {}
                        } message: {
                            Text(dietDescription.isEmpty
                                 ? "An honest yes for the whole day."
                                 : "“\(dietDescription)” — an honest yes for the whole day.")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - No junk or alcohol (inline attest, peer of diet)

/// Sixth core task, same attest interaction as the diet tile (inline button
/// behind a small confirm). After attesting, an Undo affordance sticks
/// around for the session and revokes exactly the attest it just made —
/// never an event of another kind (the DietView same-session-undo pattern,
/// held locally because AppModel has no no-junk intent yet).
struct DayBoardNoJunkTile: View {
    var done: Bool
    /// Performs the attest (client-direct logNoJunkOk); returns the logged
    /// event's uuid, or nil when the write failed — the tile then says so
    /// instead of pretending the tap landed.
    var onAttest: () -> String?
    /// Revokes the given event (this session's own attest).
    var onUndo: (String) -> Void

    @State private var confirming = false
    @State private var sessionEventUuid: String?
    @State private var attestFailed = false

    var body: some View {
        DayBoardTileChrome(done: done) {
            VStack(alignment: .leading, spacing: DromeSpacing.s) {
                DayBoardTileHeader(
                    icon: "nosign", title: "NO JUNK OR ALCOHOL", tint: .dromeCamel, done: done
                )
                HStack(spacing: DromeSpacing.m) {
                    VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                        Text(done ? "Clean all day" : "No junk food, no alcohol")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.dromeInk)
                            .lineLimit(2)
                        if !done {
                            Text(attestFailed ? "That didn't save — try again" : "Attest for today")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(attestFailed ? Color.dromeMiss : Color.dromeInk.opacity(0.55))
                        }
                    }
                    Spacer(minLength: 0)
                    if !done {
                        Button {
                            confirming = true
                        } label: {
                            Text("I kept it clean")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.dromeSand)
                                .padding(.horizontal, DromeSpacing.m)
                                .frame(minHeight: DromeSpacing.tapTarget)
                                .background(Capsule().fill(Color.dromeClay))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Attest no junk or alcohol today")
                        .confirmationDialog(
                            "No junk or alcohol today?",
                            isPresented: $confirming,
                            titleVisibility: .visible
                        ) {
                            Button("Yes — clean all day") { attest() }
                            Button("Not yet", role: .cancel) {}
                        } message: {
                            Text("An honest yes for the whole day.")
                        }
                    } else if let uuid = sessionEventUuid {
                        Button {
                            onUndo(uuid)
                            sessionEventUuid = nil
                        } label: {
                            Text("Undo")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Color.dromeInk.opacity(0.7))
                                .padding(.horizontal, DromeSpacing.m)
                                .frame(minHeight: DromeSpacing.tapTarget)
                                .background(Capsule().strokeBorder(Color.dromeInk.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Undo today's no junk attest")
                    }
                }
            }
        }
    }

    private func attest() {
        if let uuid = onAttest() {
            sessionEventUuid = uuid
            attestFailed = false
        } else {
            attestFailed = true
        }
    }
}

// MARK: - Photo (inline check-off; camera/attach flows come later)

struct DayBoardPhotoTile: View {
    var done: Bool
    var onOpen: () -> Void
    var onMarkDone: () -> Void

    var body: some View {
        DayBoardTileChrome(done: done) {
            HStack(spacing: DromeSpacing.m) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                        DayBoardTileHeader(icon: "camera.fill", title: "PHOTO", tint: .dromeClay, done: done)
                        Text(done ? "Progress photo logged" : "Take today's progress photo")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.dromeInk)
                        Text("Stays on this device")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.dromeInk.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Photo done" : "Photo, open")
                if !done {
                    Button(action: onMarkDone) {
                        Text("Mark done")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.dromeClay)
                            .padding(.horizontal, DromeSpacing.m)
                            .frame(minHeight: DromeSpacing.tapTarget)
                            .background(Capsule().strokeBorder(Color.dromeClay, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark photo done")
                }
            }
        }
    }
}

// MARK: - Weekly extra (visibly secondary; never gates the day)

struct DayBoardWeekExtraTile: View {
    var state: WeekExtraState
    var weekIndex: Int
    var onMarkDone: () -> Void

    var body: some View {
        DayBoardTileChrome(done: state.doneThisWeek, secondary: true) {
            VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                HStack(spacing: DromeSpacing.s) {
                    Text("WEEK \(weekIndex)")
                        .font(.caption2.weight(.black))
                        .tracking(1.2)
                        .monospacedDigit()
                        .foregroundStyle(Color.dromeCamel)
                        .padding(.horizontal, DromeSpacing.s)
                        .padding(.vertical, DromeSpacing.xs)
                        .background(Capsule().fill(Color.dromeCamel.opacity(0.14)))
                    Text(state.extra.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.dromeInk.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if state.doneThisWeek {
                        HStack(spacing: DromeSpacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Done")
                        }
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.dromeDone)
                    } else {
                        Button(action: onMarkDone) {
                            Text("Done")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Color.dromeInk.opacity(0.75))
                                .padding(.horizontal, DromeSpacing.m)
                                .frame(minHeight: DromeSpacing.tapTarget)
                                .background(Capsule().strokeBorder(Color.dromeInk.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mark \(state.extra.name) done for week \(weekIndex)")
                    }
                }
                Text("Weekly extra · doesn't gate your day")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.dromeInk.opacity(0.45))
            }
        }
    }
}

// MARK: - Previews

#Preview("Tiles — open vs done") {
    let openDay = DayState(
        date: "2026-07-04", dayIndex: 14, outOfRange: false,
        waterTotalMl: 1420, waterGoalMl: 3785, waterDone: false,
        outdoorWorkoutDone: true, secondWorkoutDone: false,
        workouts: [WorkoutEntry(id: "w1", durationMin: 35, outdoor: true, note: "Morning walk")],
        pagesRead: 4, readingDone: false, dietDone: false, noJunkDone: false, photoDone: false,
        extrasDone: [], coreComplete: false, isClosed: false, isBackfilled: false
    )
    let doneDay = DayState(
        date: "2026-07-03", dayIndex: 13, outOfRange: false,
        waterTotalMl: 3900, waterGoalMl: 3785, waterDone: true,
        outdoorWorkoutDone: true, secondWorkoutDone: true,
        workouts: [
            WorkoutEntry(id: "w2", durationMin: 45, outdoor: true, note: "Run"),
            WorkoutEntry(id: "w3", durationMin: 30, outdoor: false, note: "Lifting"),
        ],
        pagesRead: 12, readingDone: true, dietDone: true, noJunkDone: true, photoDone: true,
        extrasDone: [], coreComplete: true, isClosed: false, isBackfilled: false
    )
    let extra = ExtraDef(id: "job_application", name: "Apply to a job", cadence: .weekly, enabled: true)

    return ScrollView {
        VStack(spacing: DromeSpacing.s) {
            DayBoardWaterTile(day: openDay) {}
            DayBoardWaterTile(day: doneDay) {}
            DayBoardWorkoutsTile(day: openDay, onOpen: {}, onLogSlot: { _ in }, onUndoEntry: { _ in })
            DayBoardWorkoutsTile(day: doneDay, onOpen: {}, onLogSlot: { _ in }, onUndoEntry: { _ in })
            DayBoardReadingTile(day: openDay, book: "Atomic Habits") {}
            DayBoardReadingTile(day: doneDay, book: "Atomic Habits") {}
            DayBoardDietTile(dietDescription: "no junk, no alcohol", done: false, onAttest: {})
            DayBoardDietTile(dietDescription: "no junk, no alcohol", done: true, onAttest: {})
            DayBoardNoJunkTile(done: false, onAttest: { "preview-uuid" }, onUndo: { _ in })
            DayBoardNoJunkTile(done: true, onAttest: { nil }, onUndo: { _ in })
            DayBoardPhotoTile(done: false, onOpen: {}, onMarkDone: {})
            DayBoardPhotoTile(done: true, onOpen: {}, onMarkDone: {})
            DayBoardWeekExtraTile(
                state: WeekExtraState(extra: extra, doneThisWeek: false, doneOnDate: nil),
                weekIndex: 2, onMarkDone: {}
            )
            DayBoardWeekExtraTile(
                state: WeekExtraState(extra: extra, doneThisWeek: true, doneOnDate: "2026-07-01"),
                weekIndex: 2, onMarkDone: {}
            )
        }
        .padding(DromeSpacing.m)
    }
    .background(Color.dromeSand)
}
