//
//  CompletionMomentView.swift
//  Drome
//
//  The completion moment — shown exactly once when a log flips the day to
//  fully complete (AppModel.pendingCompletionMoment; integration wires the
//  presentation). Earned intensity: a weight-plate slam, not a party popper.
//  No confetti, no partial-credit variant.
//
//  Also exports WeeklyMomentView — the deliberately smaller, quieter card for
//  a completed weekly extra. Visually junior to the daily moment.
//
//  All timings and copy live in the tuning enums below so playtesting with
//  my sister's group can adjust them without touching layout code.
//

import SwiftUI
import UIKit

// MARK: - Tuning knobs (timings — tweak freely during playtesting)

private enum MomentTiming {
    // Daily sequence. Steps sum to ~2.5 s from appear to settled card.
    /// Hold on the bare near-black night before "DAY N" slams in.
    static let nightHold: TimeInterval = 0.15
    /// Gap between the DAY slam and "DONE."
    static let doneDelay: TimeInterval = 0.55
    /// The beat before "That was hard. You did it." + the run line.
    static let messageDelay: TimeInterval = 0.60
    /// Gap before the seal stamps in.
    static let sealDelay: TimeInterval = 0.60
    /// Gap before settling into the dismissable card.
    static let settleDelay: TimeInterval = 0.60

    /// Scale the slammed elements drop in from (plate hitting the floor).
    static let slamStartScale: CGFloat = 1.55
    /// Scale the seal stamps down from.
    static let sealStartScale: CGFloat = 1.45

    static let slamSpring = Animation.spring(response: 0.28, dampingFraction: 0.62)
    static let sealSpring = Animation.spring(response: 0.35, dampingFraction: 0.55)
    static let settleSpring = Animation.spring(response: 0.45, dampingFraction: 0.85)
    static let fade = Animation.easeOut(duration: 0.30)

    // Weekly moment (quiet by design).
    static let weeklyScrimOpacity: Double = 0.25
    static let weeklyStartScale: CGFloat = 0.94
    static let weeklyEntrance = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

// MARK: - Tuning knobs (copy — tweak freely during playtesting)

private enum MomentCopy {
    static func day(_ n: Int) -> String { "DAY \(n)" }
    static let done = "DONE."
    static let message = "That was hard. You did it."
    static func run(_ n: Int) -> String { n == 1 ? "RUN: 1 DAY" : "RUN: \(n) DAYS" }
    static let dismiss = "ONWARD"

    static func weekTitle(_ n: Int) -> String { "WEEK \(n)" }
    static func weekLine(_ extraName: String) -> String { "\(extraName) — done." }
    static let weekDismiss = "OK"
}

// MARK: - Daily completion moment

/// Full-screen overlay for the daily completion moment. Presented by the
/// integration layer when `appModel.pendingCompletionMoment` fires; call
/// `onDismiss` to clear the flag and tear the overlay down.
///
/// The whole sequence is skippable: a tap during the animation jumps straight
/// to the settled card; a tap on the settled card (or its button) dismisses.
@MainActor
struct CompletionMomentView: View {
    let dayIndex: Int
    let currentRun: Int
    let onDismiss: () -> Void

    private enum Phase: Int, Comparable {
        case night, day, done, message, seal, settled

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @State private var phase: Phase = .night
    @State private var sequence: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Forced-dark below makes this the near-black night, in both
            // ambient appearances — the moment always happens at night.
            Color.dromeSand.ignoresSafeArea()

            content
                .padding(.horizontal, DromeSpacing.l)
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .environment(\.colorScheme, .dark)
        .onAppear { start() }
        .onDisappear { sequence?.cancel() }
        .accessibilityAction(named: "Dismiss") { onDismiss() }
    }

    // MARK: Layout

    private var content: some View {
        VStack(spacing: DromeSpacing.m) {
            Text(MomentCopy.day(dayIndex))
                .font(.system(size: 72, weight: .black))
                .monospacedDigit()
                .tracking(-2)
                .foregroundStyle(Color.dromeInk)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .opacity(phase >= .day ? 1 : 0)
                .scaleEffect(phase >= .day ? 1 : MomentTiming.slamStartScale)

            Text(MomentCopy.done)
                .font(.system(size: 44, weight: .black))
                .tracking(-1)
                .foregroundStyle(Color.dromeClay)
                .opacity(phase >= .done ? 1 : 0)
                .scaleEffect(phase >= .done ? 1 : MomentTiming.slamStartScale)

            VStack(spacing: DromeSpacing.s) {
                Text(MomentCopy.message)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.dromeInk.opacity(0.85))
                    .multilineTextAlignment(.center)

                Text(MomentCopy.run(currentRun))
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .tracking(1.5)
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
            }
            .padding(.top, DromeSpacing.s)
            .opacity(phase >= .message ? 1 : 0)

            SealMark(size: 88, color: .dromeClay)
                .padding(.top, DromeSpacing.m)
                .opacity(phase >= .seal ? 1 : 0)
                .scaleEffect(phase >= .seal ? 1 : MomentTiming.sealStartScale)

            if phase == .settled {
                Button(action: onDismiss) {
                    Text(MomentCopy.dismiss)
                        .font(.system(size: 17, weight: .black))
                        .tracking(1)
                        .foregroundStyle(Color.dromeSand)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.dromeClay)
                        )
                }
                .dromeTapTarget()
                .padding(.top, DromeSpacing.l)
                .transition(.opacity)
            }
        }
        .padding(phase == .settled ? DromeSpacing.l : 0)
        .background {
            if phase == .settled {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.dromeInk.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.dromeInk.opacity(0.14), lineWidth: 1)
                    )
                    .transition(.opacity)
            }
        }
    }

    // MARK: Sequence

    private func start() {
        guard sequence == nil else { return }
        if reduceMotion {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .settled
            return
        }
        sequence = Task { await runSequence() }
    }

    private func runSequence() async {
        let slam = UIImpactFeedbackGenerator(style: .heavy)
        let success = UINotificationFeedbackGenerator()
        let stamp = UIImpactFeedbackGenerator(style: .rigid)
        slam.prepare()
        success.prepare()

        guard await pause(MomentTiming.nightHold) else { return }
        withAnimation(MomentTiming.slamSpring) { phase = .day }
        slam.impactOccurred(intensity: 1.0)

        guard await pause(MomentTiming.doneDelay) else { return }
        withAnimation(MomentTiming.slamSpring) { phase = .done }
        success.notificationOccurred(.success)
        stamp.prepare()

        guard await pause(MomentTiming.messageDelay) else { return }
        withAnimation(MomentTiming.fade) { phase = .message }

        guard await pause(MomentTiming.sealDelay) else { return }
        withAnimation(MomentTiming.sealSpring) { phase = .seal }
        stamp.impactOccurred(intensity: 0.7)

        guard await pause(MomentTiming.settleDelay) else { return }
        withAnimation(MomentTiming.settleSpring) { phase = .settled }
    }

    /// Sleeps, then reports whether the sequence should keep going.
    private func pause(_ seconds: TimeInterval) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled && phase != .settled
    }

    private func handleTap() {
        if phase == .settled {
            onDismiss()
        } else {
            // Skip the sequence, no haptic replay — straight to the card.
            sequence?.cancel()
            withAnimation(MomentTiming.settleSpring) { phase = .settled }
        }
    }
}

// MARK: - Weekly extra moment (deliberately junior to the daily moment)

/// Small, quiet card for a completed weekly extra ("Week 2: application
/// sent."). One soft haptic, a gentle entrance, no takeover. Presented by the
/// integration layer; scrim tap, OK button, and the accessibility action all
/// call `onDismiss`.
@MainActor
struct WeeklyMomentView: View {
    let weekIndex: Int
    let extraName: String
    let onDismiss: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.dromeInk.opacity(MomentTiming.weeklyScrimOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            card
                .scaleEffect(appeared ? 1 : MomentTiming.weeklyStartScale)
                .opacity(appeared ? 1 : 0)
                .padding(.horizontal, DromeSpacing.l)
        }
        .onAppear {
            guard !appeared else { return }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(MomentTiming.weeklyEntrance) { appeared = true }
            }
        }
        .accessibilityAction(named: "Dismiss") { onDismiss() }
    }

    private var card: some View {
        HStack(spacing: DromeSpacing.m) {
            SealMark(size: 40, color: .dromeCamel)

            VStack(alignment: .leading, spacing: DromeSpacing.xs) {
                Text(MomentCopy.weekTitle(weekIndex))
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .tracking(1.5)
                    .foregroundStyle(Color.dromeInk.opacity(0.6))

                Text(MomentCopy.weekLine(extraName))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.dromeInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DromeSpacing.s)

            Button(action: onDismiss) {
                Text(MomentCopy.weekDismiss)
                    .font(.system(size: 15, weight: .black))
                    .tracking(1)
                    .foregroundStyle(Color.dromeClay)
            }
            .dromeTapTarget()
        }
        .padding(DromeSpacing.l)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.dromeSand)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.dromeInk.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: Color.dromeInk.opacity(0.15), radius: 16, x: 0, y: 6)
    }
}

// MARK: - Seal mark (self-contained celebratory flourish; NOT CamelView)

/// A minimal stamped seal: double ring + checkmark, tilted like a rubber
/// stamp that landed slightly off-square. Simple shapes only, no emoji.
private struct SealMark: View {
    let size: CGFloat
    var color: Color = .dromeClay

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color, lineWidth: size * 0.045)
            Circle()
                .strokeBorder(color.opacity(0.45), lineWidth: size * 0.02)
                .padding(size * 0.09)
            CheckShape()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round)
                )
                .padding(size * 0.24)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-8))
        .accessibilityHidden(true)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.85))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.95, y: rect.minY + rect.height * 0.15))
        return path
    }
}

// MARK: - Previews

#Preview("Daily completion moment") {
    let model: AppModel = {
        let m = AppModel(core: MockDromeCore())
        m.refresh()
        return m
    }()
    CompletionMomentView(
        dayIndex: model.todayState?.dayIndex ?? 14,
        // The moment fires the instant today flips complete, so the run is
        // the completed-days count with today now included.
        currentRun: (model.summary?.daysCompleteCount ?? 12) + 1,
        onDismiss: {}
    )
}

#Preview("Weekly extra moment") {
    let model: AppModel = {
        let m = AppModel(core: MockDromeCore())
        m.refresh()
        return m
    }()
    ZStack {
        Color.dromeSand.ignoresSafeArea()
        WeeklyMomentView(
            weekIndex: model.todayState?.weekIndex ?? 2,
            extraName: model.todayState?.weekExtras.first?.extra.name ?? "Apply to a job",
            onDismiss: {}
        )
    }
}
