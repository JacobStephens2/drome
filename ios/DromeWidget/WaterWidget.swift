//
//  WaterWidget.swift
//  DromeWidget
//
//  The water quick-add widget — at 6–10 logs/day this is the spreadsheet
//  killer. systemSmall shows a self-drawn camel-fill gauge, remaining oz,
//  "Day N", and a pace bar whose tick drifts hourly. systemMedium adds up
//  to two interactive preset buttons (iOS 17 AppIntents).
//
//  The widget target compiles DromeShared but NOT the app's DesignSystem,
//  so the few desert-palette tokens needed here are defined locally
//  (WidgetPalette) with the exact hexes from docs/ARCHITECTURE.md.
//

import SwiftUI
import UIKit
import WidgetKit

// MARK: - Core seam

enum WidgetCore {
    // =====================================================================
    // INTEGRATION: swap to LiveDromeCore when the bindings stage lands:
    //
    //     static let client: DromeCoreClient =
    //         LiveDromeCore(dbPath: SharedPaths.databasePath)
    //
    // (the shared App Group DB — see DromeShared/SharedPaths.swift).
    // MockDromeCore is in-memory and per-process: widget logs do NOT
    // persist and are NOT visible to the app until this swap happens.
    // =====================================================================
    static let client: DromeCoreClient = MockDromeCore()
}

// MARK: - Pace-check flag (chug warning surfaced without a dialog)

/// A widget has no room for the anti-chug confirmation dialog, so when the
/// facade's chug check warns, LogWaterIntent logs NOTHING and raises this
/// flag; the next timeline render shows the "Open Drome — pace check" state.
/// The flag expires with the chug guard's trailing-hour window and clears on
/// the next successful log.
enum WidgetPaceCheck {
    private static let key = "widget.paceCheckPendingAt"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: SharedPaths.appGroupID) ?? .standard
    }

    static func setPending(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: key)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }

    static var isPending: Bool {
        let raisedAt = defaults.double(forKey: key)
        guard raisedAt > 0 else { return false }
        return Date().timeIntervalSince1970 - raisedAt < 3600
    }
}

// MARK: - Local palette (hexes pinned in docs/ARCHITECTURE.md — keep in sync)

enum WidgetPalette {
    /// Background. #F3EAD8 light / #1C1917 dark.
    static let sand = dynamic(light: 0xF3EAD8, dark: 0x1C1917)
    /// Primary text. #292524 light / #EDE3D1 dark.
    static let ink = dynamic(light: 0x292524, dark: 0xEDE3D1)
    /// Accent. #C2410C.
    static let clay = dynamic(light: 0xC2410C, dark: 0xC2410C)
    /// The camel. #B45309.
    static let camel = dynamic(light: 0xB45309, dark: 0xB45309)
    /// Water. #0E7490 light / #22D3EE dark.
    static let oasis = dynamic(light: 0x0E7490, dark: 0x22D3EE)
    /// Completed. #15803D.
    static let done = dynamic(light: 0x15803D, dark: 0x15803D)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgb & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }
}

// MARK: - Timeline entry

struct WaterEntry: TimelineEntry {
    let date: Date
    /// nil when there is no active challenge (or the store failed to open).
    let water: WaterState?
    let dayIndex: Int
    /// Up to two container presets for the interactive buttons.
    let presets: [ContainerPreset]
    /// A widget-initiated log tripped the chug guard: show "Open Drome —
    /// pace check" instead of the gauge, log nothing.
    let paceCheckPending: Bool

    /// Fixed sample for the gallery placeholder (never touches the store).
    static let placeholder = WaterEntry(
        date: .now,
        water: WaterState(
            totalMl: 2130, goalMl: 3785, remainingMl: 1655,
            paceTargetMl: 2200, onPace: true, finalOunce: false,
            discourageCatchUp: false
        ),
        dayIndex: 14,
        presets: [
            ContainerPreset(id: "bottle-24oz", name: "24 oz bottle", ml: 710, sortOrder: 0),
            ContainerPreset(id: "glass", name: "Glass", ml: 350, sortOrder: 1),
        ],
        paceCheckPending: false
    )
}

// MARK: - Timeline provider

struct WaterProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaterEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (WaterEntry) -> Void) {
        completion(context.isPreview ? .placeholder : makeEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaterEntry>) -> Void) {
        let now = Date()
        // One entry, refreshed hourly: the pace target (and its tick on the
        // bar) drifts with the clock even when no water gets logged.
        let timeline = Timeline(
            entries: [makeEntry(date: now)],
            policy: .after(now.addingTimeInterval(3600))
        )
        completion(timeline)
    }

    private func makeEntry(date: Date) -> WaterEntry {
        let client = WidgetCore.client
        let today = try? client.today()
        let presets = ((try? client.containerPresets()) ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .prefix(2)
        return WaterEntry(
            date: date,
            water: today?.water,
            dayIndex: today?.dayIndex ?? 0,
            presets: Array(presets),
            paceCheckPending: WidgetPaceCheck.isPending
        )
    }
}

// MARK: - Camel-fill gauge (simple silhouette, NOT the app's CamelView)

/// One-hump dromedary silhouette traced in a unit rect. Deliberately simple:
/// the widget draws its own compact gauge instead of importing app views.
struct CamelSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var p = Path()
        // Start at the rump, trace clockwise.
        p.move(to: pt(0.06, 0.58))
        p.addQuadCurve(to: pt(0.20, 0.38), control: pt(0.06, 0.40))
        // The single hump.
        p.addQuadCurve(to: pt(0.40, 0.16), control: pt(0.26, 0.16))
        p.addQuadCurve(to: pt(0.60, 0.38), control: pt(0.54, 0.16))
        // Neck base, neck up.
        p.addQuadCurve(to: pt(0.70, 0.34), control: pt(0.66, 0.38))
        p.addQuadCurve(to: pt(0.80, 0.12), control: pt(0.76, 0.28))
        // Head and muzzle.
        p.addQuadCurve(to: pt(0.92, 0.06), control: pt(0.84, 0.04))
        p.addQuadCurve(to: pt(0.98, 0.16), control: pt(0.99, 0.08))
        p.addQuadCurve(to: pt(0.88, 0.24), control: pt(0.94, 0.24))
        // Neck front down to the chest, into the front leg.
        p.addQuadCurve(to: pt(0.78, 0.56), control: pt(0.82, 0.40))
        p.addLine(to: pt(0.76, 0.62))
        p.addLine(to: pt(0.74, 0.98))
        p.addLine(to: pt(0.66, 0.98))
        p.addLine(to: pt(0.66, 0.66))
        // Belly across to the rear leg.
        p.addQuadCurve(to: pt(0.28, 0.66), control: pt(0.47, 0.74))
        p.addLine(to: pt(0.28, 0.98))
        p.addLine(to: pt(0.20, 0.98))
        p.addLine(to: pt(0.19, 0.64))
        // Back up to the rump.
        p.addQuadCurve(to: pt(0.06, 0.58), control: pt(0.10, 0.64))
        p.closeSubpath()
        return p
    }
}

/// The camel fills bottom-up with oasis blue as water goes down the hatch.
struct CamelFillGauge: View {
    /// 0…1 fraction of the day's goal.
    var fill: Double

    private var clamped: CGFloat { CGFloat(min(1.0, max(0.0, fill))) }

    var body: some View {
        ZStack {
            CamelSilhouette()
                .fill(WidgetPalette.ink.opacity(0.14))
            CamelSilhouette()
                .fill(WidgetPalette.oasis)
                .mask {
                    GeometryReader { geo in
                        Rectangle()
                            .path(in: CGRect(
                                x: 0,
                                y: geo.size.height * (1 - clamped),
                                width: geo.size.width,
                                height: geo.size.height * clamped
                            ))
                    }
                }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Pace bar (tick drifts as the waking window elapses)

struct PaceBar: View {
    var water: WaterState

    private var fillFraction: CGFloat {
        guard water.goalMl > 0 else { return 0 }
        return CGFloat(min(1.0, max(0.0, Double(water.totalMl) / Double(water.goalMl))))
    }

    private var paceFraction: CGFloat {
        guard water.goalMl > 0 else { return 0 }
        return CGFloat(min(1.0, max(0.0, Double(water.paceTargetMl) / Double(water.goalMl))))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WidgetPalette.ink.opacity(0.12))
                Capsule()
                    .fill(WidgetPalette.oasis)
                    .frame(width: geo.size.width * fillFraction)
                Rectangle()
                    .fill(WidgetPalette.clay)
                    .frame(width: 2, height: geo.size.height + 4)
                    .offset(x: geo.size.width * paceFraction - 1, y: -2)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared bits

private enum WaterCopy {
    static func remainingOz(_ water: WaterState) -> Int {
        Int(WaterUnits.flOz(fromMl: water.remainingMl).rounded(.up))
    }

    static func presetOz(_ preset: ContainerPreset) -> Int {
        Int(WaterUnits.flOz(fromMl: preset.ml).rounded())
    }
}

struct DayBadge: View {
    var dayIndex: Int

    var body: some View {
        Text("DAY \(dayIndex)")
            .font(.system(size: 11, weight: .black))
            .tracking(0.8)
            .monospacedDigit()
            .foregroundStyle(WidgetPalette.ink.opacity(0.75))
    }
}

/// Honest one-word pace status. `dromeDone` green is reserved for goal met;
/// "BEHIND" is plain clay — informative, never shaming.
struct PaceCaption: View {
    var water: WaterState

    var body: some View {
        Group {
            if water.remainingMl <= 0 {
                EmptyView()
            } else if water.discourageCatchUp {
                Text("DON'T CHUG").foregroundStyle(WidgetPalette.clay)
            } else if water.finalOunce {
                Text("FINAL OUNCE").foregroundStyle(WidgetPalette.camel)
            } else if water.onPace {
                Text("ON PACE").foregroundStyle(WidgetPalette.oasis)
            } else {
                Text("BEHIND").foregroundStyle(WidgetPalette.clay)
            }
        }
        .font(.system(size: 9, weight: .heavy))
        .tracking(0.6)
    }
}

struct RemainingLine: View {
    var water: WaterState

    var body: some View {
        if water.remainingMl <= 0 {
            Text("Goal met")
                .font(.system(size: 20, weight: .black))
                .tracking(-0.3)
                .foregroundStyle(WidgetPalette.done)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(WaterCopy.remainingOz(water))")
                    .font(.system(size: 24, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(WidgetPalette.ink)
                Text("oz left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WidgetPalette.ink.opacity(0.7))
            }
        }
    }
}

// MARK: - Family layouts

struct SmallWaterView: View {
    var water: WaterState
    var dayIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DayBadge(dayIndex: dayIndex)
                Spacer(minLength: 0)
                PaceCaption(water: water)
            }
            CamelFillGauge(fill: fillFraction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            RemainingLine(water: water)
            PaceBar(water: water)
        }
    }

    private var fillFraction: Double {
        guard water.goalMl > 0 else { return 0 }
        return Double(water.totalMl) / Double(water.goalMl)
    }
}

struct MediumWaterView: View {
    var water: WaterState
    var dayIndex: Int
    var presets: [ContainerPreset]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    DayBadge(dayIndex: dayIndex)
                    Spacer(minLength: 0)
                    PaceCaption(water: water)
                }
                CamelFillGauge(fill: fillFraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RemainingLine(water: water)
                PaceBar(water: water)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                ForEach(effectivePresets) { preset in
                    PresetButton(preset: preset)
                }
            }
            .frame(width: 132)
        }
    }

    private var fillFraction: Double {
        guard water.goalMl > 0 else { return 0 }
        return Double(water.totalMl) / Double(water.goalMl)
    }

    private var effectivePresets: [ContainerPreset] {
        if presets.isEmpty {
            return [ContainerPreset(id: "widget-default-glass", name: "Glass", ml: 350, sortOrder: 0)]
        }
        return Array(presets.prefix(2))
    }
}

/// Interactive quick-add (iOS 17 AppIntents). 44pt+ tap target.
struct PresetButton: View {
    var preset: ContainerPreset

    var body: some View {
        Button(intent: LogWaterIntent(presetMl: preset.ml, label: preset.name)) {
            HStack(spacing: 6) {
                Text("+\(WaterCopy.presetOz(preset))oz")
                    .font(.system(size: 15, weight: .black))
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(preset.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(WidgetPalette.ink)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                WidgetPalette.oasis.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Log \(preset.name), \(WaterCopy.presetOz(preset)) ounces")
    }
}

// MARK: - Non-gauge states

/// Shown after a widget log tripped the chug guard: nothing was logged;
/// confirming an over-limit pour needs the app's full dialog.
struct PaceCheckView: View {
    var body: some View {
        VStack(spacing: 6) {
            CamelSilhouette()
                .fill(WidgetPalette.clay.opacity(0.85))
                .frame(width: 72, height: 48)
            Text("Open Drome")
                .font(.system(size: 16, weight: .black))
                .tracking(-0.3)
                .foregroundStyle(WidgetPalette.ink)
            Text("Pace check — that's a lot at once")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WidgetPalette.ink.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoChallengeView: View {
    var body: some View {
        VStack(spacing: 6) {
            CamelSilhouette()
                .fill(WidgetPalette.camel.opacity(0.6))
                .frame(width: 72, height: 48)
            Text("Open Drome")
                .font(.system(size: 16, weight: .black))
                .tracking(-0.3)
                .foregroundStyle(WidgetPalette.ink)
            Text("Set up your challenge")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WidgetPalette.ink.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Root view & widget

struct WaterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WaterEntry

    var body: some View {
        if entry.paceCheckPending {
            PaceCheckView()
        } else if let water = entry.water {
            switch family {
            case .systemMedium:
                MediumWaterView(water: water, dayIndex: entry.dayIndex, presets: entry.presets)
            default:
                SmallWaterView(water: water, dayIndex: entry.dayIndex)
            }
        } else {
            NoChallengeView()
        }
    }
}

struct WaterWidget: Widget {
    static let kind = "DromeWaterWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: WaterProvider()) { entry in
            WaterWidgetView(entry: entry)
                .containerBackground(WidgetPalette.sand, for: .widget)
        }
        .configurationDisplayName("Water")
        .description("Camel fill, ounces left, quick add.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Previews (MockDromeCore-backed)

extension WaterEntry {
    /// demo fixture via MockDromeCore: day 14, ~40% water.
    static var previewLive: WaterEntry {
        let client: DromeCoreClient = MockDromeCore()
        let today = try? client.today()
        let presets = ((try? client.containerPresets()) ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .prefix(2)
        return WaterEntry(
            date: .now,
            water: today?.water,
            dayIndex: today?.dayIndex ?? 0,
            presets: Array(presets),
            paceCheckPending: false
        )
    }

    static var previewGoalMet: WaterEntry {
        WaterEntry(
            date: .now,
            water: WaterState(
                totalMl: 3785, goalMl: 3785, remainingMl: 0,
                paceTargetMl: 3200, onPace: true, finalOunce: false,
                discourageCatchUp: false
            ),
            dayIndex: 14,
            presets: WaterEntry.placeholder.presets,
            paceCheckPending: false
        )
    }

    static var previewPaceCheck: WaterEntry {
        WaterEntry(
            date: .now,
            water: WaterEntry.placeholder.water,
            dayIndex: 14,
            presets: WaterEntry.placeholder.presets,
            paceCheckPending: true
        )
    }
}

#Preview("Small", as: .systemSmall) {
    WaterWidget()
} timeline: {
    WaterEntry.previewLive
    WaterEntry.previewGoalMet
    WaterEntry.previewPaceCheck
}

#Preview("Medium", as: .systemMedium) {
    WaterWidget()
} timeline: {
    WaterEntry.previewLive
    WaterEntry.previewGoalMet
    WaterEntry.previewPaceCheck
}
