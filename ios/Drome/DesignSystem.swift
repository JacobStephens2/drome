//
//  DesignSystem.swift
//  Drome
//
//  Design tokens ONLY (docs/ARCHITECTURE.md, "Swift layer contracts").
//  No feature UI here; no hex literals in feature views — always use these.
//

import SwiftUI
import UIKit

// MARK: - Colors (light/dark pairs, defined in code, not assets)

extension Color {
    /// Background. #F3EAD8 light / #1C1917 dark.
    static let dromeSand = Color(light: 0xF3EAD8, dark: 0x1C1917)
    /// Primary text. #292524 light / #EDE3D1 dark.
    static let dromeInk = Color(light: 0x292524, dark: 0xEDE3D1)
    /// Accent. #C2410C.
    static let dromeClay = Color(light: 0xC2410C, dark: 0xC2410C)
    /// The camel. #B45309.
    static let dromeCamel = Color(light: 0xB45309, dark: 0xB45309)
    /// Water. #0E7490 light / #22D3EE dark.
    static let dromeOasis = Color(light: 0x0E7490, dark: 0x22D3EE)
    /// Completed. #15803D.
    static let dromeDone = Color(light: 0x15803D, dark: 0x15803D)
    /// Missed — used sparingly; honest, not shaming. #B91C1C.
    static let dromeMiss = Color(light: 0xB91C1C, dark: 0xB91C1C)

    private init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Spacing

enum DromeSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32

    /// Minimum tap target edge (generous, one-hand reach).
    static let tapTarget: CGFloat = 44
}

// MARK: - Type styles ("gear, not toy")

/// Header style: system font, `.black` weight, tight tracking.
private struct DromeTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 28, weight: .black))
            .tracking(-0.5)
            .foregroundStyle(Color.dromeInk)
    }
}

/// Counter style: big, `.black`, monospaced digits so numbers don't jitter.
private struct DromeCounterStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 40, weight: .black))
            .monospacedDigit()
            .tracking(-0.5)
            .foregroundStyle(Color.dromeInk)
    }
}

extension View {
    func dromeTitle() -> some View {
        modifier(DromeTitleStyle())
    }

    func dromeCounter() -> some View {
        modifier(DromeCounterStyle())
    }

    /// Enforces the minimum 44pt tap target.
    func dromeTapTarget() -> some View {
        frame(minWidth: DromeSpacing.tapTarget, minHeight: DromeSpacing.tapTarget)
    }
}
