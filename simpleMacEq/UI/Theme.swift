import SwiftUI
import AppKit

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }

    /// Appearance-adaptive color built from two hex values (auto light/dark).
    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255,
                           alpha: 1)
        })
    }
}

/// Semantic design tokens. Palette anchored to the design file:
/// dark bg #1e1e24, accent #5b8cff, light surfaces #ffffff/#ededf1/#dcdce2.
enum Theme {
    static let accent         = Color(hex: 0x5b8cff)
    static let background      = Color.adaptive(light: 0xffffff, dark: 0x1e1e24)
    static let surface         = Color.adaptive(light: 0xf2f2f6, dark: 0x2a2a32)
    static let surfaceStroke   = Color.adaptive(light: 0xdcdce2, dark: 0x3a3a44)
    static let textPrimary     = Color.adaptive(light: 0x1e1e24, dark: 0xffffff)
    static let textSecondary   = Color.adaptive(light: 0x7a7a88, dark: 0x9a9aa6)
    static let trackInactive   = Color.adaptive(light: 0xdcdce2, dark: 0x3a3a44)
}
