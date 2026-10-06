import SwiftUI
import UIKit

/// Brand palette stays fixed; semantic UI colors adapt for readable Light Mode.
enum WaymateTheme {
    static let black = color(0x050607)
    static let white = color(0xF3F4EF)
    static let ice = color(0xB8EDF5)
    static let graphite = color(0x303539)
    static let road = color(0x42474B)
    static let green = color(0x69D494)
    static let amber = color(0xE6C84F)
    static let red = color(0xFF4B43)

    static let background = adaptive(light: 0xF3F4EF, dark: 0x050607)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x303539)
    static let text = adaptive(light: 0x050607, dark: 0xF3F4EF)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let accent = Color("AccentColor")
    static let connected = adaptive(light: 0x216C42, dark: 0x69D494)
    static let warning = adaptive(light: 0x766000, dark: 0xE6C84F)
    static let error = adaptive(light: 0xB5241D, dark: 0xFF766F)
    static let onAccent = adaptive(light: 0xF3F4EF, dark: 0x050607)
    static let onError = adaptive(light: 0xF3F4EF, dark: 0x050607)

    /// Shared fixed-width, rounded Wayline stroke for paths and brand components.
    static func waylineStroke(width: CGFloat = 3) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func color(_ hex: UInt32) -> Color { Color(uiColor: uiColor(hex)) }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}
