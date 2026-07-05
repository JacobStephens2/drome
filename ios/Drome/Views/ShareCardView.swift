//
//  ShareCardView.swift
//  Drome
//
//  The share card that replaces group-chat workout screenshots. Renders a
//  story-proportioned (9:16, designed at 360×640pt, exported 1080×1920 @3x)
//  card from ShareCardData: day number, date, the six-task checklist (done
//  flags straight from the core — backfilled flags carry no quantities), the
//  day's workouts with durations + OUTDOOR badges, the current run, and the
//  honest-but-subtle ruleset label. Structurally photo-free and note-free:
//  ShareCardData carries no photo refs or workout notes, ever
//  (docs/ARCHITECTURE.md guardrails; notes are private).
//
//  The card pins its own light desert palette so it renders identically
//  regardless of the app's light/dark appearance — a share card is a fixed
//  artifact, not a themed surface.
//

import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - Card

/// The 9:16 story card. Fixed 360×640pt design size; export at 3× scale.
struct ShareCardView: View {

    static let designSize = CGSize(width: 360, height: 640)

    let data: ShareCardData

    init(data: ShareCardData) {
        self.data = data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: DromeSpacing.m)
            dayBlock
            Spacer(minLength: DromeSpacing.m)
            checklist
            Spacer(minLength: DromeSpacing.m)
            workoutsBlock
            Spacer(minLength: DromeSpacing.m)
            runBlock
            footer
        }
        .padding(28)
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .background(Color.dromeSand)
        // Standalone artifact: always the light desert palette, independent of
        // the app's appearance. Dynamic tokens resolve against this.
        .environment(\.colorScheme, .light)
    }

    // MARK: Header (wordmark + camel mark)

    private var header: some View {
        HStack(spacing: DromeSpacing.s) {
            CamelMarkShape()
                .fill(Color.dromeCamel)
                .frame(width: 30, height: 22)
            Text("DROME")
                .font(.system(size: 15, weight: .black))
                .tracking(3)
                .foregroundStyle(Color.dromeInk)
            Spacer()
            if data.coreComplete {
                HStack(spacing: DromeSpacing.xs) {
                    Image(systemName: "checkmark.square.fill")
                        .font(.system(size: 12, weight: .black))
                    Text("COMPLETE")
                        .font(.system(size: 12, weight: .black))
                        .tracking(1.5)
                }
                .foregroundStyle(Color.dromeDone)
            }
        }
    }

    // MARK: Day number + date

    private var dayBlock: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.xs) {
            Text("DAY \(data.dayIndex)")
                .font(.system(size: 84, weight: .black))
                .monospacedDigit()
                .tracking(-3)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(Color.dromeInk)
            HStack(spacing: DromeSpacing.s) {
                Text(displayDate)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Color.dromeInk.opacity(0.7))
                if data.isBackfilled {
                    badge("BACKFILLED")
                }
                if data.outOfRange {
                    // The day number is clamped to [1, lengthDays]; this badge
                    // keeps a pre-start or post-challenge card honest.
                    badge("OUTSIDE CHALLENGE")
                }
            }
        }
    }

    /// Small outlined honesty badge (BACKFILLED / OUTSIDE CHALLENGE).
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .tracking(1.5)
            .foregroundStyle(Color.dromeInk.opacity(0.55))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.dromeInk.opacity(0.35), lineWidth: 1)
            )
    }

    // MARK: Checklist (the six tasks)

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.dromeInk)
                .frame(height: 3)
                .padding(.bottom, DromeSpacing.s)
            ForEach(taskRows) { row in
                HStack(spacing: DromeSpacing.s + 2) {
                    Image(systemName: row.done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(row.done ? Color.dromeDone : Color.dromeInk.opacity(0.35))
                    Text(row.title)
                        .font(.system(size: 16, weight: .black))
                        .tracking(1)
                        .foregroundStyle(Color.dromeInk)
                    Spacer()
                    if let detail = row.detail {
                        Text(detail)
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .tracking(0.5)
                            .foregroundStyle(Color.dromeInk.opacity(0.65))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Workouts (what the group actually shares)

    private var workoutsBlock: some View {
        VStack(alignment: .leading, spacing: DromeSpacing.s) {
            Text("WORKOUTS")
                .font(.system(size: 11, weight: .black))
                .tracking(2.5)
                .foregroundStyle(Color.dromeInk.opacity(0.55))
            if data.workouts.isEmpty {
                Text(data.isBackfilled ? "LOGGED VIA BACKFILL" : "NONE LOGGED")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.dromeInk.opacity(0.45))
            } else {
                ForEach(shownWorkouts) { workout in
                    HStack(spacing: DromeSpacing.s) {
                        Text("\(workout.durationMin) MIN")
                            .font(.system(size: 16, weight: .black))
                            .monospacedDigit()
                            .foregroundStyle(Color.dromeInk)
                            .frame(width: 76, alignment: .leading)
                        Spacer()
                        if workout.outdoor {
                            Text("OUTDOOR")
                                .font(.system(size: 10, weight: .black))
                                .tracking(1.5)
                                .foregroundStyle(Color.dromeSand)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.dromeClay, in: Capsule())
                        }
                    }
                }
                if data.workouts.count > maxWorkoutRows {
                    Text("+ \(data.workouts.count - maxWorkoutRows) MORE")
                        .font(.system(size: 12, weight: .black))
                        .monospacedDigit()
                        .tracking(1.5)
                        .foregroundStyle(Color.dromeInk.opacity(0.5))
                }
            }
        }
    }

    // MARK: Run + footer

    private var runBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.dromeInk.opacity(0.25))
                .frame(height: 1)
                .padding(.bottom, DromeSpacing.s + 2)
            HStack(alignment: .firstTextBaseline) {
                Text("CURRENT RUN")
                    .font(.system(size: 12, weight: .black))
                    .tracking(2)
                    .foregroundStyle(Color.dromeInk.opacity(0.6))
                Spacer()
                Text(data.currentRun == 1 ? "1 DAY" : "\(data.currentRun) DAYS")
                    .font(.system(size: 24, weight: .black))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(Color.dromeInk)
            }
        }
    }

    private var footer: some View {
        Text("\(data.rulesetLabel.uppercased()) MODE · \(data.dayIndex) OF \(data.lengthDays)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .tracking(2)
            .foregroundStyle(Color.dromeInk.opacity(0.45))
            .padding(.top, DromeSpacing.m)
    }

    // MARK: Derived rows

    private struct TaskRow: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let done: Bool
    }

    private var maxWorkoutRows: Int { 4 }

    private var shownWorkouts: [ShareWorkout] {
        Array(data.workouts.prefix(maxWorkoutRows))
    }

    /// The six checklist rows. Done-ness comes from the core's per-task flags
    /// (never recomputed from totals here — backfilled flags carry no
    /// quantities); totals only feed the detail strings.
    private var taskRows: [TaskRow] {
        let oz = Int(WaterUnits.flOz(fromMl: data.waterTotalMl).rounded())
        let goalOz = Int(WaterUnits.flOz(fromMl: data.waterGoalMl).rounded())
        return [
            TaskRow(
                id: "water",
                title: "WATER",
                detail: data.isBackfilled && data.waterTotalMl == 0 ? nil : "\(oz) / \(goalOz) OZ",
                done: data.waterDone
            ),
            TaskRow(
                id: "workouts",
                title: "WORKOUTS ×2",
                detail: data.workouts.isEmpty ? nil : "\(data.workouts.count) LOGGED",
                done: data.outdoorWorkoutDone && data.secondWorkoutDone
            ),
            TaskRow(
                id: "reading",
                title: "READING",
                detail: data.pagesRead > 0 ? "\(data.pagesRead) PAGES" : nil,
                done: data.readingDone
            ),
            TaskRow(id: "diet", title: "DIET", detail: nil, done: data.dietDone),
            TaskRow(id: "no-junk", title: "NO JUNK OR ALCOHOL", detail: nil, done: data.noJunkDone),
            TaskRow(id: "photo", title: "PHOTO", detail: nil, done: data.photoDone),
        ]
    }

    // MARK: Date formatting

    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private var displayDate: String {
        guard let parsed = Self.parseFormatter.date(from: data.date) else {
            return data.date
        }
        return Self.displayFormatter.string(from: parsed).uppercased()
    }
}

// MARK: - Camel mark (self-contained simple vector; one hump — a dromedary)

private struct CamelMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: at(0.04, 0.62))                                        // tail root
        path.addQuadCurve(to: at(0.16, 0.34), control: at(0.05, 0.40))       // rump
        path.addQuadCurve(to: at(0.38, 0.16), control: at(0.24, 0.12))       // up the hump
        path.addQuadCurve(to: at(0.58, 0.38), control: at(0.52, 0.16))       // down the hump
        path.addQuadCurve(to: at(0.70, 0.20), control: at(0.66, 0.34))       // neck rising
        path.addQuadCurve(to: at(0.78, 0.06), control: at(0.72, 0.10))       // toward head
        path.addQuadCurve(to: at(0.94, 0.10), control: at(0.88, 0.00))       // head top
        path.addQuadCurve(to: at(0.90, 0.22), control: at(0.98, 0.18))       // muzzle
        path.addQuadCurve(to: at(0.80, 0.30), control: at(0.84, 0.26))       // jaw
        path.addQuadCurve(to: at(0.74, 0.52), control: at(0.76, 0.38))       // neck front
        path.addLine(to: at(0.74, 0.96))                                     // front leg
        path.addLine(to: at(0.67, 0.96))
        path.addLine(to: at(0.66, 0.62))
        path.addQuadCurve(to: at(0.34, 0.62), control: at(0.50, 0.68))       // belly
        path.addLine(to: at(0.33, 0.96))                                     // hind leg
        path.addLine(to: at(0.26, 0.96))
        path.addLine(to: at(0.24, 0.58))
        path.addQuadCurve(to: at(0.04, 0.62), control: at(0.12, 0.62))       // back to tail
        path.closeSubpath()
        return path
    }
}

// MARK: - Transferable image wrapper

/// Minimal Transferable wrapper for the rendered card so ShareLink can hand
/// a PNG to iMessage / Instagram stories / anywhere else.
struct ShareCardImage: Transferable {
    let uiImage: UIImage
    let title: String

    var previewImage: Image { Image(uiImage: uiImage) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { card in
            guard let data = card.uiImage.pngData() else {
                throw DromeError.storage("could not encode share card image")
            }
            return data
        }
        .suggestedFileName("drome-day.png")
    }
}

// MARK: - Share sheet

/// Card preview + ShareLink. Present with `.sheet`. Renders the card to a
/// UIImage via ImageRenderer at 3× (1080×1920) so the shared artifact is
/// pixel-identical to the preview.
struct ShareCardSheet: View {

    private let data: ShareCardData

    @Environment(\.dismiss) private var dismiss
    @State private var shareImage: ShareCardImage?

    init(data: ShareCardData) {
        self.data = data
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DromeSpacing.m) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                shareButton
            }
            .padding(DromeSpacing.m)
            .background(Color.dromeSand.ignoresSafeArea())
            .navigationTitle("Share card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.dromeClay)
                        .dromeTapTarget()
                }
            }
        }
        .task { renderIfNeeded() }
    }

    @ViewBuilder
    private var preview: some View {
        if let shareImage {
            shareImage.previewImage
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: Color.dromeInk.opacity(0.25), radius: 12, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.dromeInk.opacity(0.08))
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay(ProgressView().tint(Color.dromeClay))
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            ShareLink(
                item: shareImage,
                preview: SharePreview(shareImage.title, image: shareImage.previewImage)
            ) {
                shareLabel(enabled: true)
            }
        } else {
            shareLabel(enabled: false)
        }
    }

    private func shareLabel(enabled: Bool) -> some View {
        Label("Share Day \(data.dayIndex)", systemImage: "square.and.arrow.up")
            .font(.system(size: 17, weight: .black))
            .monospacedDigit()
            .foregroundStyle(Color.dromeSand)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                Color.dromeClay.opacity(enabled ? 1 : 0.4),
                in: RoundedRectangle(cornerRadius: 14)
            )
    }

    @MainActor
    private func renderIfNeeded() {
        guard shareImage == nil else { return }
        let renderer = ImageRenderer(content: ShareCardView(data: data))
        renderer.scale = 3 // 360×640pt design → 1080×1920px story
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { return }
        shareImage = ShareCardImage(uiImage: image, title: "Drome — Day \(data.dayIndex)")
    }
}

// MARK: - Previews

#Preview("Card — partial day (demo day 14)") {
    let core = MockDromeCore()
    let today = try! core.today().date
    return ScrollView {
        ShareCardView(data: try! core.shareCard(date: today))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding()
    }
}

#Preview("Card — complete day") {
    let core = MockDromeCore()
    _ = try! core.logWater(ml: 2400)
    _ = try! core.logWorkout(durationMin: 30, outdoor: false, note: "Lifting")
    _ = try! core.logReading(bookTitle: "Atomic Habits", pages: 12)
    _ = try! core.logDietOk()
    _ = try! core.logNoJunkOk()
    _ = try! core.logPhotoDone(photoRef: nil)
    let today = try! core.today().date
    return ScrollView {
        ShareCardView(data: try! core.shareCard(date: today))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding()
    }
}

#Preview("Card — backfilled day 1") {
    let core = MockDromeCore()
    let summary = try! core.summary()
    let briefs = try! core.calendar(from: summary.startDate, to: summary.startDate)
    return ShareCardView(data: try! core.shareCard(date: briefs[0].date))
}

#Preview("Card — partial backfill (day 13)") {
    // Fixture day 13: water done via a backfill flag (no quantity), workouts/
    // diet/photo event-logged, reading missing. Water must render checked.
    let core = MockDromeCore()
    let summary = try! core.summary()
    let today = try! core.today().date
    let briefs = try! core.calendar(from: summary.startDate, to: today)
    return ScrollView {
        ShareCardView(data: try! core.shareCard(date: briefs[12].date))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding()
    }
}

#Preview("Card — outside challenge (post-day-75)") {
    ShareCardView(data: ShareCardData(
        date: "2026-09-10",
        dayIndex: 75, // core clamps; outOfRange carries the truth
        lengthDays: 75,
        outOfRange: true,
        rulesetLabel: "Flexible",
        coreComplete: true,
        currentRun: 3,
        waterTotalMl: 3800,
        waterGoalMl: 3785,
        waterDone: true,
        outdoorWorkoutDone: true,
        secondWorkoutDone: true,
        pagesRead: 12,
        readingDone: true,
        dietDone: true,
        noJunkDone: true,
        photoDone: true,
        workouts: [
            ShareWorkout(id: "w0", durationMin: 45, outdoor: true),
            ShareWorkout(id: "w1", durationMin: 30, outdoor: false),
        ],
        isBackfilled: false
    ))
}

#Preview("Sheet") {
    let core = MockDromeCore()
    let today = try! core.today().date
    return ShareCardSheet(data: try! core.shareCard(date: today))
        .environment(AppModel(core: core))
}
