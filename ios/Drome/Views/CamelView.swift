//
//  CamelView.swift
//  Drome
//
//  Jerome the camel — the app's emotional centerpiece, behind a pinned API:
//
//      CamelView(fill: Double, celebrating: Bool)
//
//  `fill` (0…1) fills the silhouette bottom-up with a gently animated water
//  wave (dromeOasis); the empty part stays outline-only. `celebrating` adds a
//  small satisfied bounce/wiggle — never confetti. Placeholder vector art:
//  swap the geometry in `CamelSilhouette` when final art lands; the API and
//  everything that uses it stay put. Self-contained: no AppModel dependency.
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
        .aspectRatio(CamelGeometry.aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jerome the camel, \(Int((clampedFill * 100).rounded())) percent full of water")
    }

    @ViewBuilder
    private func artwork(time t: TimeInterval) -> some View {
        let wiggle = celebrating ? sin(t * 4.5) : 0

        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let unit = CamelGeometry.unitScale(in: rect)

            ZStack {
                // Two offset waves for a little depth, clipped to the camel.
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
                .clipShape(CamelSilhouette())

                CamelSilhouette()
                    .stroke(Color.dromeCamel,
                            style: StrokeStyle(lineWidth: max(1.5, 1.6 * unit),
                                               lineCap: .round,
                                               lineJoin: .round))

                CamelEye()
                    .fill(Color.dromeInk)
            }
            .animation(.snappy(duration: 0.6), value: clampedFill)
        }
        .rotationEffect(.degrees(wiggle * 2), anchor: .bottom)
        .offset(y: celebrating ? -abs(wiggle) * 3 : 0)
    }
}

// MARK: - Geometry (design space 100 × 80, aspect-fit into the view rect)

private enum CamelGeometry {
    static let designWidth: CGFloat = 100
    static let designHeight: CGFloat = 80
    static var aspectRatio: CGFloat { designWidth / designHeight }

    /// Points per design unit for an aspect-fit of the design space in `rect`.
    static func unitScale(in rect: CGRect) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return min(rect.width / designWidth, rect.height / designHeight)
    }

    /// The centered, aspect-fit rect the camel is drawn into.
    static func fittedRect(in rect: CGRect) -> CGRect {
        let s = unitScale(in: rect)
        let size = CGSize(width: designWidth * s, height: designHeight * s)
        return CGRect(x: rect.midX - size.width / 2,
                      y: rect.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}

// MARK: - Silhouette

/// One closed path: dromedary facing left — muzzle, ear, neck dip, single
/// hump, tail, four legs with rounded feet, chest. Interior is the fill mask.
private struct CamelSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let f = CamelGeometry.fittedRect(in: rect)
        let s = CamelGeometry.unitScale(in: rect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: f.minX + x * s, y: f.minY + y * s)
        }

        var path = Path()
        // Muzzle and head
        path.move(to: p(6, 22))
        path.addQuadCurve(to: p(16, 13), control: p(7, 13.5))
        // Ear
        path.addQuadCurve(to: p(18.5, 11.5), control: p(17, 11))
        path.addQuadCurve(to: p(20.5, 14), control: p(19.8, 11.8))
        // Back of neck down into the dip
        path.addCurve(to: p(35, 28), control1: p(27, 17), control2: p(31, 23))
        // The hump
        path.addCurve(to: p(55, 10), control1: p(38, 22), control2: p(46, 10))
        path.addCurve(to: p(74, 25), control1: p(63, 10), control2: p(70, 17))
        // Rump and tail
        path.addQuadCurve(to: p(84.5, 31), control: p(80, 26))
        path.addQuadCurve(to: p(90.5, 34), control: p(89, 30.5))
        path.addQuadCurve(to: p(92, 51), control: p(93, 43))
        path.addQuadCurve(to: p(89.5, 52), control: p(90.5, 53.5))
        path.addQuadCurve(to: p(87.5, 38), control: p(89, 44))
        // Hind near leg
        path.addQuadCurve(to: p(85.5, 44), control: p(86, 40.5))
        path.addLine(to: p(86.5, 73))
        path.addQuadCurve(to: p(84.5, 76), control: p(86.5, 75.8))
        path.addLine(to: p(81.5, 76))
        path.addQuadCurve(to: p(79.5, 73), control: p(79.5, 75.8))
        path.addLine(to: p(79, 57))
        // Hind far leg
        path.addQuadCurve(to: p(75, 57), control: p(77, 53))
        path.addLine(to: p(75.5, 73))
        path.addQuadCurve(to: p(73.5, 76), control: p(75.5, 75.8))
        path.addLine(to: p(70.5, 76))
        path.addQuadCurve(to: p(68.5, 73), control: p(68.5, 75.8))
        path.addLine(to: p(68, 53))
        // Belly
        path.addQuadCurve(to: p(46, 52), control: p(57, 56))
        // Front near leg
        path.addLine(to: p(46.5, 73))
        path.addQuadCurve(to: p(44.5, 76), control: p(46.5, 75.8))
        path.addLine(to: p(41.5, 76))
        path.addQuadCurve(to: p(39.5, 73), control: p(39.5, 75.8))
        path.addLine(to: p(39, 57))
        // Front far leg
        path.addQuadCurve(to: p(35, 57), control: p(37, 53))
        path.addLine(to: p(35.5, 73))
        path.addQuadCurve(to: p(33.5, 76), control: p(35.5, 75.8))
        path.addLine(to: p(30.5, 76))
        path.addQuadCurve(to: p(28.5, 73), control: p(28.5, 75.8))
        path.addLine(to: p(28.5, 46))
        // Chest, throat, chin
        path.addCurve(to: p(13.5, 26.5), control1: p(27.5, 36), control2: p(22, 28))
        path.addQuadCurve(to: p(7.5, 26), control: p(10, 27.5))
        path.addQuadCurve(to: p(6, 22), control: p(5.8, 24.5))
        path.closeSubpath()
        return path
    }
}

/// The eye — drawn over both outline and water so Drome always looks back.
private struct CamelEye: Shape {
    func path(in rect: CGRect) -> Path {
        let f = CamelGeometry.fittedRect(in: rect)
        let s = CamelGeometry.unitScale(in: rect)
        let center = CGPoint(x: f.minX + 13.5 * s, y: f.minY + 18 * s)
        let r = 1.3 * s
        return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                      width: r * 2, height: r * 2))
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
        let f = CamelGeometry.fittedRect(in: rect)
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
