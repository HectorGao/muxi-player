import SwiftUI
import AppKit

enum AppearanceMode: String, CaseIterable {
    case system, dark, light

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "夜潮 · 深色"
        case .light: return "晴汐 · 浅色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum Theme {
    static let canvas = adaptive(
        light: NSColor(srgbRed: 0.95, green: 0.97, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.035, green: 0.06, blue: 0.09, alpha: 1))
    static let surface = adaptive(
        light: NSColor(srgbRed: 0.99, green: 1, blue: 1, alpha: 1),
        dark: NSColor(srgbRed: 0.075, green: 0.115, blue: 0.15, alpha: 1))
    static let accent = adaptive(
        light: NSColor(srgbRed: 0.07, green: 0.38, blue: 0.43, alpha: 1),
        dark: NSColor(srgbRed: 0.95, green: 0.76, blue: 0.46, alpha: 1))
    static let border = adaptive(
        light: NSColor(srgbRed: 0.08, green: 0.21, blue: 0.27, alpha: 0.14),
        dark: NSColor(srgbRed: 0.78, green: 0.88, blue: 0.94, alpha: 0.15))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
