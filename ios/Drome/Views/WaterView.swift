//
//  WaterView.swift
//  Drome
//
//  Water tracking: big remaining-oz counter, Jerome the camel filling with
//  water, honest pace line, one-tap container presets, custom amount, undo.
//
//  Chug safety (binding, all modes): every log routes through AppModel's
//  check-then-confirm flow. A warned log shows an honest confirmation alert —
//  "log anyway" requires an explicit tap and is never celebrated. When the
//  core reports `discourageCatchUp`, the pace line switches to the safety
//  message; this screen never cheers late-night catch-up.
//
//  Display is fluid ounces; storage is milliliters (the core's canonical unit).
//
//  Drag to pour: dragging up on Jerome previews a pour by raising the water
//  line under the finger; release logs the previewed amount through the exact
//  same check-then-confirm flow the presets use. Dragging DOWN is the mirror:
//  it previews lowering the line and release logs a signed correction
//  (logWaterAdjustment) for over-recorded water — no chug gate, because
//  decreasing needs no safety confirmation. Nothing is logged — and no
//  counter or pace line moves — until release.
//

import SwiftUI
import UIKit

struct WaterView: View {

    @Environment(AppModel.self) private var appModel

    @State private var showingCustomAmount = false
    @State private var pendingCustomMl: Int64?

    /// Today's non-revoked pours (core-attributed, so the amounts always sum
    /// to the day's water total). Reloaded in `.task` and after every
    /// log/revoke/confirm via the `waterState` change hook — every one of
    /// those paths ends in `appModel.refresh()`, which recomputes waterState.
    @State private var pourLog: [WaterLogEntry] = []

    // Drag-to-pour preview state (direct manipulation of the water line).
    // Signed: positive while dragging up (pour), negative while dragging
    // down (correction).
    @State private var dragPendingMl: Int64 = 0
    @State private var isDragging = false
    @State private var dragHapticStep = 0
    @State private var dragHaptics = UISelectionFeedbackGenerator()
    @AppStorage("hasDragPoured") private var hasDragPoured = false

    /// True while a drag pour is parked behind the chug alert. Lets the
    /// alert's "Log anyway" retire the discoverability caption — a warned
    /// pour the user explicitly confirms IS a successful drag log.
    @State private var dragAwaitingChugConfirm = false

    /// Cancellation sentinel. Unlike `onEnded`, @GestureState resets on BOTH
    /// a normal end and a system cancellation (incoming call, backgrounding,
    /// the hosting sheet's dismiss pan taking over), so watching it drop lets
    /// us clear a preview that `onEnded` never got the chance to clean up.
    @GestureState private var dragGestureActive = false

    var body: some View {
        ZStack {
            Color.dromeSand.ignoresSafeArea()

            VStack(spacing: DromeSpacing.m) {
                header
                counterBlock
                CamelView(fill: fillFraction, celebrating: goalMet)
                    .frame(maxHeight: 280)
                    .overlay {
                        // Hit area for the pour gesture, sized to the camel's
                        // rendered frame so drag distance maps onto the fill.
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(pourGesture(camelHeight: proxy.size.height))
                        }
                    }
                    .overlay(alignment: .top) { pendingPill }
                    .accessibilityHint("Drag up to pour water, or drag down to remove water recorded by mistake. The buttons below log preset amounts.")
                    .padding(.horizontal, DromeSpacing.l)
                if !hasDragPoured {
                    Text("Drag Jerome up to add water")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dromeInk.opacity(0.45))
                }
                paceLine
                Spacer(minLength: DromeSpacing.s)
                presetRow
                poursSection
                actionRow
            }
            .padding(.horizontal, DromeSpacing.m)
            .padding(.top, DromeSpacing.m)
            .padding(.bottom, DromeSpacing.s)
        }
        .task {
            appModel.refresh()
            reloadPourLog()
        }
        .onChange(of: appModel.waterState) { _, _ in
            reloadPourLog()
        }
        .onChange(of: dragGestureActive) { _, active in
            // A normal release runs `onEnded` first (which clears these); if
            // the sentinel drops while the preview is still up, the system
            // cancelled the drag mid-pour — settle Jerome back down so he
            // never keeps showing water that was never logged.
            if !active, isDragging {
                dragHapticStep = 0
                withAnimation(.snappy) {
                    isDragging = false
                    dragPendingMl = 0
                }
            }
        }
        .sheet(isPresented: $showingCustomAmount) {
            // Log after the sheet is fully gone so a chug alert can present.
            if let ml = pendingCustomMl {
                pendingCustomMl = nil
                appModel.logWater(ml: ml)
            }
        } content: {
            CustomAmountSheet { ml in pendingCustomMl = ml }
        }
        .alert("Over 34 oz in an hour", isPresented: chugAlertPresented) {
            Button("Log anyway") {
                let previousUuid = appModel.lastWaterEventUuid
                appModel.confirmPendingWater()
                // A confirmed pour that came from a drag and actually logged
                // is a successful drag log: retire the caption.
                if dragAwaitingChugConfirm, appModel.lastWaterEventUuid != previousUuid {
                    hasDragPoured = true
                }
                dragAwaitingChugConfirm = false
            }
            Button("Wait", role: .cancel) {
                appModel.cancelPendingWater()
                dragAwaitingChugConfirm = false
            }
        } message: {
            Text(chugMessage)
        }
    }

    // MARK: - Water state helpers

    private var water: WaterState? { appModel.waterState }

    /// Camel fill: actual total plus the drag-pour preview. Only Jerome shows
    /// the preview — the counters and pace line deliberately ignore it because
    /// nothing is logged until the finger lifts. (CamelView clamps to 0…1.)
    private var fillFraction: Double {
        guard let water, water.goalMl > 0 else { return 0 }
        return Double(water.totalMl + dragPendingMl) / Double(water.goalMl)
    }

    private var goalMet: Bool {
        guard let water else { return false }
        return water.goalMl > 0 && water.remainingMl <= 0
    }

    // MARK: - Drag to pour (supplementary; presets/custom stay the accessible path)

    /// Finger travel as a fraction of the camel's height maps straight onto
    /// the fill — the user drags the water line up (pour) or down (correct
    /// over-recorded water) with their finger. The pending amount snaps to
    /// whole ounces in both directions. Upward previews are clamped so they
    /// never exceed the goal (the metaphor is the water line: it tops out at
    /// a full camel; larger logs stay available via presets/custom); downward
    /// previews never exceed today's current total (the line bottoms out at
    /// an empty camel) — both respect the core's per-log cap.
    private func pourGesture(camelHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragGestureActive) { _, state, _ in state = true }
            .onChanged { value in
                guard let water, water.goalMl > 0, camelHeight > 0 else { return }
                if !isDragging {
                    dragHaptics.prepare()
                    withAnimation(.snappy) { isDragging = true }
                }
                // Signed: up is a pour (+), down a correction (−).
                let fraction = -value.translation.height / camelHeight
                let snappedOz = (WaterUnits.flOz(fromMl: water.goalMl) * fraction).rounded()
                if snappedOz < 0 {
                    // Clamp so the pending correction never exceeds today's
                    // current total (there is nothing below an empty camel to
                    // take back) nor the core's per-log cap. (WaterUnits.ml
                    // floors negatives at 0, so convert the magnitude.)
                    dragPendingMl = -min(WaterUnits.ml(fromFlOz: -snappedOz), water.totalMl, AppModel.maxWaterPerLogMl)
                } else {
                    let capMl = max(0, water.goalMl - water.totalMl)
                    // Clamp to the remaining goal (the water line tops out at
                    // a full camel) AND to the core's per-log cap — with a
                    // goal over 338 oz a full drag must never build a single
                    // log the core would reject.
                    dragPendingMl = min(WaterUnits.ml(fromFlOz: snappedOz), capMl, AppModel.maxWaterPerLogMl)
                }
                // A selection tick each time the previewed amount crosses an
                // 8 oz step (in either direction), so a long drag "clicks" as
                // it grows. Integer division truncates toward zero, keeping
                // the steps symmetric around the start point.
                let step = ozSigned(dragPendingMl) / 8
                if step != dragHapticStep {
                    dragHapticStep = step
                    dragHaptics.selectionChanged()
                }
            }
            .onEnded { _ in
                dragHapticStep = 0
                if dragCommitsOnRelease {
                    commitDragPour(dragPendingMl)
                } else {
                    // Sub-ounce nudge: nothing to log; settle back down.
                    withAnimation(.snappy) {
                        isDragging = false
                        dragPendingMl = 0
                    }
                }
            }
    }

    /// True when releasing now will log the preview (in either direction).
    /// ONE predicate shared by `onEnded` and the pill, so the pill never
    /// promises a log that release would silently cancel. Below a whole ounce
    /// an upward pour still commits when it exactly tops off the remaining
    /// goal (recomputed here, at release time) — otherwise the "drink the
    /// final ounce" state would be the one state drag-to-pour can never log.
    /// A sub-ounce downward nudge always cancels: corrections have no
    /// equivalent must-reach state.
    private var dragCommitsOnRelease: Bool {
        if dragPendingMl <= -WaterUnits.ml(fromFlOz: 1) { return true }
        guard dragPendingMl > 0 else { return false }
        if dragPendingMl >= WaterUnits.ml(fromFlOz: 1) { return true }
        guard let water else { return false }
        return dragPendingMl == max(0, water.goalMl - water.totalMl)
    }

    /// Routes the previewed amount through the EXACT same path as the preset
    /// buttons — AppModel's check-then-confirm chug flow. Never calls the
    /// client directly, never skips the guard. A negative preview (drag down)
    /// commits as a signed correction instead — no chug gate, because
    /// decreasing recorded water needs no safety confirmation.
    private func commitDragPour(_ ml: Int64) {
        if ml < 0 {
            appModel.logWaterAdjustment(ml: ml)
            // Synchronous like the pour path: the model has refreshed with
            // the lowered total, so clearing the preview is a no-op for the
            // fill (preview == logged correction; no double jump).
            withAnimation(.snappy) {
                isDragging = false
                dragPendingMl = 0
            }
            return
        }
        let previousUuid = appModel.lastWaterEventUuid
        let warned = appModel.checkThenLogWater(ml: ml) != nil
        // DromeCoreClient is synchronous, so by the time that returns the
        // model has either refreshed with the new total — clearing the preview
        // here is a no-op for the fill (preview == logged amount; no double
        // jump) — or parked the log behind the chug alert, in which case the
        // preview honestly animates back down (nothing was logged).
        withAnimation(.snappy) {
            isDragging = false
            dragPendingMl = 0
        }
        // The first drag-log that actually happens retires the discoverability
        // caption. A chug-warned pour counts only once the user explicitly
        // confirms it — `dragAwaitingChugConfirm` carries that into the
        // alert's "Log anyway" action.
        if warned {
            dragAwaitingChugConfirm = true
        } else if appModel.lastWaterEventUuid != previousUuid {
            hasDragPoured = true
        }
    }

    /// Bold "+N oz" / "−N oz" pill floating over Jerome while the finger is
    /// down. Shown exactly when release will log (`dragCommitsOnRelease`) —
    /// never promising a log that would cancel. A sub-ounce top-off displays
    /// as 1 oz (the same never-show-zero convention as `ozCeil`); every other
    /// preview is already snapped to whole ounces.
    @ViewBuilder
    private var pendingPill: some View {
        if isDragging, dragCommitsOnRelease {
            Text(dragPendingMl < 0 ? "−\(oz(-dragPendingMl)) oz" : "+\(max(1, oz(dragPendingMl))) oz")
                .font(.system(size: 20, weight: .black))
                .monospacedDigit()
                .padding(.horizontal, DromeSpacing.m)
                .padding(.vertical, DromeSpacing.s)
                .background(Color.dromeOasis, in: Capsule())
                .foregroundStyle(Color.dromeSand)
                .offset(y: -DromeSpacing.s)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("WATER").dromeTitle()
            Spacer()
            if let dayIndex = appModel.todayState?.dayIndex {
                Text("DAY \(dayIndex)")
                    .font(.system(size: 15, weight: .black))
                    .monospacedDigit()
                    .tracking(0.5)
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            }
        }
    }

    // MARK: - Counter

    @ViewBuilder
    private var counterBlock: some View {
        VStack(spacing: DromeSpacing.xs) {
            if let water {
                if goalMet {
                    Text(water.goalMl == WaterUnits.mlPerGallon ? "GALLON. DONE." : "GOAL. DONE.")
                        .font(.system(size: 34, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(Color.dromeDone)
                } else if water.finalOunce {
                    Text("Almost. Drink the final ounce.")
                        .font(.system(size: 24, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(Color.dromeOasis)
                        .multilineTextAlignment(.center)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.s) {
                        Text("\(ozCeil(water.remainingMl))")
                            .dromeCounter()
                        Text("oz to go")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.dromeInk.opacity(0.65))
                    }
                }
                Text("\(oz(water.totalMl)) of \(oz(water.goalMl)) oz")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.dromeInk.opacity(0.55))
            } else {
                Text("—").dromeCounter()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pace (honest, not naggy)

    @ViewBuilder
    private var paceLine: some View {
        if let water {
            Text(paceText(for: water))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(paceColor(for: water))
                .multilineTextAlignment(.center)
                .padding(.horizontal, DromeSpacing.m)
        }
    }

    private func paceText(for water: WaterState) -> String {
        if goalMet {
            return "Goal met. You don't need more today."
        }
        if water.discourageCatchUp {
            return "It's late and \(ozCeil(water.remainingMl)) oz remain. Don't chug to catch up — your body handles about 34 oz an hour. Log what you actually drink."
        }
        if water.onPace {
            return "On pace. Target by now: \(oz(water.paceTargetMl)) oz."
        }
        let behindOz = ozCeil(water.paceTargetMl - water.totalMl)
        return "Behind pace by \(behindOz) oz. Steady sips."
    }

    private func paceColor(for water: WaterState) -> Color {
        if goalMet { return .dromeDone }
        if water.discourageCatchUp { return .dromeClay }
        return Color.dromeInk.opacity(0.65)
    }

    // MARK: - Presets (one tap = log)

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DromeSpacing.s) {
                ForEach(appModel.presets) { preset in
                    Button {
                        appModel.logWater(preset: preset)
                    } label: {
                        VStack(spacing: 2) {
                            Text("+\(oz(preset.ml)) oz")
                                .font(.system(size: 18, weight: .black))
                                .monospacedDigit()
                            Text(preset.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, DromeSpacing.m)
                        .frame(minWidth: 104, minHeight: 60)
                        .background(Color.dromeOasis, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color.dromeSand)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Log \(preset.name), \(oz(preset.ml)) ounces")
                }
            }
            .padding(.horizontal, DromeSpacing.xs)
        }
    }

    // MARK: - Today's pours (per-entry removal)

    /// The shared pour ledger (PourLogList): newest pour first — the row just
    /// logged is always visible, never hidden behind the inner scroll — swipe
    /// to remove, capped at three visible rows. Jerome stays the star.
    private var poursSection: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("TODAY'S POURS")
                .font(.system(size: 12, weight: .black))
                .tracking(1)
                .foregroundStyle(Color.dromeInk.opacity(0.45))
            if pourLog.isEmpty {
                Text("No pours yet today.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.4))
                    .frame(height: PourLogList.rowHeight)
            } else {
                PourLogList(entries: pourLog) { entry in
                    appModel.revoke(eventUuid: entry.id)
                    reloadPourLog()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small reload keeping the list in view-local @State: the pour log is a
    /// per-screen detail, not app-wide state, so AppModel doesn't own it.
    private func reloadPourLog() {
        guard let date = appModel.todayState?.date else {
            pourLog = []
            return
        }
        pourLog = (try? appModel.client.waterLog(date: date)) ?? []
    }

    // MARK: - Custom + undo

    private var actionRow: some View {
        HStack(spacing: DromeSpacing.s) {
            Button {
                showingCustomAmount = true
            } label: {
                Label("Custom", systemImage: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.dromeInk.opacity(0.35), lineWidth: 1.5)
            )
            .foregroundStyle(Color.dromeInk)

            // Targeted undo: revokes exactly the last WATER event logged from
            // the app — never a workout/diet/photo log. Hidden when there is
            // no water event to take back. Deliberately NOT delegated to the
            // pour list's newest row: a widget-logged pour this model never
            // tracked could be newest, and "undo last" must only take back
            // what the user logged here.
            if appModel.lastWaterEventUuid != nil {
                Button {
                    appModel.undoLastWater()
                } label: {
                    Label("Undo last", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.dromeInk.opacity(0.35), lineWidth: 1.5)
                )
                .foregroundStyle(Color.dromeInk)
            }
        }
    }

    // MARK: - Chug safety alert

    /// Both alert buttons clear the model's pending state themselves, so the
    /// binding's setter is a no-op (SwiftUI flips it false before the action
    /// runs; clearing here would swallow the confirmation).
    private var chugAlertPresented: Binding<Bool> {
        Binding(
            get: { appModel.pendingChugWarning != nil },
            set: { _ in }
        )
    }

    private var chugMessage: String {
        guard let check = appModel.pendingChugWarning else { return "" }
        let trailing = oz(check.trailingHourMl)
        let adding = oz(check.addMl)
        let limit = oz(check.limitMl)
        return "You've logged \(trailing) oz in the last hour; \(adding) oz more puts you past about \(limit) oz within an hour. Kidneys process roughly 27–34 oz an hour — it counts just the same in a while."
    }
}

// MARK: - Ounce display (storage is ml; round sensibly)

/// Nearest ounce — for totals, goals, presets.
private func oz(_ ml: Int64) -> Int {
    max(0, Int(WaterUnits.flOz(fromMl: ml).rounded()))
}

/// Rounded up — for remaining/behind amounts, so a nonzero remainder never
/// shows as "0 oz to go".
private func ozCeil(_ ml: Int64) -> Int {
    max(0, Int(WaterUnits.flOz(fromMl: ml).rounded(.up)))
}

/// Nearest ounce, sign preserved — for the signed drag preview (`oz` floors
/// negatives at 0, which would erase a downward drag's haptic steps).
private func ozSigned(_ ml: Int64) -> Int {
    Int(WaterUnits.flOz(fromMl: ml).rounded())
}

// MARK: - Custom amount sheet (oz numeric pad)

private struct CustomAmountSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var ozText = ""
    @FocusState private var fieldFocused: Bool

    /// Milliliters to log, delivered on dismiss via the parent.
    let onLog: (Int64) -> Void

    private var ozValue: Int? {
        guard let value = Int(ozText), value > 0, value <= 200 else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: DromeSpacing.l) {
            Text("CUSTOM AMOUNT")
                .font(.system(size: 14, weight: .black))
                .tracking(1)
                .foregroundStyle(Color.dromeInk.opacity(0.55))

            HStack(alignment: .firstTextBaseline, spacing: DromeSpacing.s) {
                TextField("0", text: $ozText)
                    .keyboardType(.numberPad)
                    .focused($fieldFocused)
                    .font(.system(size: 44, weight: .black))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 130)
                    .foregroundStyle(Color.dromeInk)
                Text("oz")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.dromeInk.opacity(0.65))
            }

            Button {
                if let value = ozValue {
                    onLog(WaterUnits.ml(fromFlOz: Double(value)))
                    dismiss()
                }
            } label: {
                Text(ozValue.map { "Log \($0) oz" } ?? "Log")
                    .font(.system(size: 17, weight: .black))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: DromeSpacing.tapTarget + 6)
                    .background(Color.dromeOasis, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Color.dromeSand)
            }
            .buttonStyle(.plain)
            .disabled(ozValue == nil)
            .opacity(ozValue == nil ? 0.4 : 1)
        }
        .padding(DromeSpacing.l)
        .presentationDetents([.height(300)])
        .presentationBackground(Color.dromeSand)
        .onAppear { fieldFocused = true }
    }
}

// MARK: - Previews

#Preview("Partial day (demo fixture)") {
    WaterView()
        .environment(AppModel())
}

#Preview("At goal") {
    WaterView()
        .environment(atGoalModel())
}

#Preview("Final ounce") {
    WaterView()
        .environment(finalOunceModel())
}

@MainActor
private func atGoalModel() -> AppModel {
    let core = MockDromeCore()
    // Top the fixture's partial day up past the gallon, directly on the core
    // (bypasses the chug check on purpose — this is preview seeding, not UI).
    if let remaining = try? core.waterState().remainingMl, remaining > 0 {
        _ = try? core.logWater(ml: remaining, effectiveDate: nil)
    }
    let model = AppModel(core: core)
    model.refresh()
    return model
}

@MainActor
private func finalOunceModel() -> AppModel {
    let core = MockDromeCore()
    if let remaining = try? core.waterState().remainingMl, remaining > 100 {
        _ = try? core.logWater(ml: remaining - 100, effectiveDate: nil)
    }
    let model = AppModel(core: core)
    model.refresh()
    return model
}
