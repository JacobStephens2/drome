//
//  CamelView.swift
//  Drome
//
//  Jerome the camel — the app's emotional centerpiece, behind a pinned API:
//
//      CamelView(fill: Double, celebrating: Bool)
//
//  `fill` (0…1) fills Melissa's refined Jerome silhouette bottom-up with a
//  gently animated water wave (dromeOasis); the empty part stays as the
//  original orange trace. `celebrating` adds a small satisfied bounce/wiggle
//  — never confetti. Self-contained: no AppModel dependency.
//

import SwiftUI

struct CamelView: View {

    /// Water fill fraction, 0…1, bottom-up. Values outside the range clamp.
    var fill: Double
    /// Small satisfied bounce/wiggle while true.
    var celebrating: Bool

    private var clampedFill: Double { min(1, max(0, fill)) }

    /// No motion to draw: not celebrating and the water line is invisible.
    private var animationPaused: Bool {
        !celebrating && (clampedFill <= 0 || clampedFill >= 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: animationPaused)) { context in
            artwork(time: context.date.timeIntervalSinceReferenceDate)
        }
        .aspectRatio(JeromeGeometry.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jerome the camel, \(Int((clampedFill * 100).rounded())) percent full of water")
    }

    @ViewBuilder
    private func artwork(time t: TimeInterval) -> some View {
        let wiggle = celebrating ? sin(t * 4.5) : 0

        ZStack {
            // The two wave layers, alpha mask, outline, and eye all share the
            // accepted 540 150 2480 2800 SVG crop and the same scaled-to-fit
            // bounds. Keeping them as sibling assets prevents any drift.
            ZStack {
                CamelWaveShape(level: clampedFill,
                               phase: t * 1.1 + .pi / 1.6,
                               amplitudeScale: 0.7,
                               levelNudge: 0.014)
                    .fill(Color.dromeOasis.opacity(0.45))
                CamelWaveShape(level: clampedFill,
                               phase: t * 1.5,
                               amplitudeScale: 1,
                               levelNudge: 0)
                    .fill(Color.dromeOasis)
            }
            .mask {
                Image("JeromeFillMask")
                    .resizable()
                    .scaledToFit()
            }

            Image("JeromeTrace")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.dromeCamel)

            // The eye is one of Melissa's original trace paths, isolated so
            // it can retain the app's ink treatment over every water level.
            Image("JeromeEye")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.dromeInk)
        }
        .animation(.snappy(duration: 0.6), value: clampedFill)
        .rotationEffect(.degrees(wiggle * 2), anchor: .bottom)
        .offset(y: celebrating ? -abs(wiggle) * 3 : 0)
    }
}

// MARK: - Geometry

/// The accepted web crop. Both image assets were produced against this exact
/// view box, so the source proportions remain authoritative in SwiftUI.
private enum JeromeGeometry {
    static let designWidth: CGFloat = 2_480
    static let designHeight: CGFloat = 2_800
    static var aspectRatio: CGFloat { designWidth / designHeight }

    /// The centered, aspect-fit rect the camel is drawn into.
    static func fittedRect(in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let s = min(rect.width / designWidth, rect.height / designHeight)
        let size = CGSize(width: designWidth * s, height: designHeight * s)
        return CGRect(x: rect.midX - size.width / 2,
                      y: rect.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}

// MARK: - Water wave

/// A filled region from the bottom of the camel's fitted rect up to the water
/// line, with a gentle sine surface. Amplitude tapers to zero near empty and
/// full so the wave never pokes past the silhouette's extremes.
private struct CamelWaveShape: Shape {
    var level: Double
    var phase: Double
    var amplitudeScale: CGFloat
    var levelNudge: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let f = JeromeGeometry.fittedRect(in: rect)
        guard f.width > 0, f.height > 0 else { return Path() }

        let l = min(1, max(0, level + (level > 0 ? levelNudge : 0)))
        guard l > 0 else { return Path() }

        let surfaceY = f.maxY - f.height * CGFloat(l)
        let taper = CGFloat(min(1, min(l, 1 - l) * 10))
        let amplitude = f.height * 0.022 * amplitudeScale * taper
        let wavelength = f.width / 1.4

        var path = Path()
        var x = rect.minX
        let step = max(2, rect.width / 80)
        func waveY(at x: CGFloat) -> CGFloat {
            surfaceY + sin(((x - f.minX) / wavelength) * 2 * .pi + CGFloat(phase)) * amplitude
        }
        path.move(to: CGPoint(x: x, y: waveY(at: x)))
        while x < rect.maxX {
            x = min(x + step, rect.maxX)
            path.addLine(to: CGPoint(x: x, y: waveY(at: x)))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

#Preview("Fill levels") {
    VStack(spacing: DromeSpacing.l) {
        HStack(spacing: DromeSpacing.l) {
            CamelView(fill: 0, celebrating: false)
            CamelView(fill: 0.35, celebrating: false)
        }
        HStack(spacing: DromeSpacing.l) {
            CamelView(fill: 0.72, celebrating: false)
            CamelView(fill: 1, celebrating: false)
        }
    }
    .padding(DromeSpacing.l)
    .background(Color.dromeSand)
}

#Preview("Celebrating") {
    CamelView(fill: 1, celebrating: true)
        .padding(DromeSpacing.xl)
        .background(Color.dromeSand)
}
