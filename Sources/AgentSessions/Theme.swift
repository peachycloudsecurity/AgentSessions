import AppKit
import SwiftUI

// MARK: - Appearance preference

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Palette

/// Every colour is appearance-adaptive: AppKit resolves the right variant from
/// the view's effective appearance, so call sites never branch on the theme.
enum Theme {
    // Surfaces
    static let bg         = dyn(light: 0xFFFFFF, dark: 0x09090B)
    static let bgElevated = dyn(light: 0xF4F4F5, dark: 0x18181B)
    static let bgHover    = dyn(light: 0xF4F4F5, dark: 0x18181B, lightAlpha: 0.9, darkAlpha: 0.6)

    // Borders
    static let border     = dyn(light: 0xE4E4E7, dark: 0x27272A, lightAlpha: 1.0, darkAlpha: 0.6)
    static let borderSoft = dyn(light: 0xF4F4F5, dark: 0x27272A, lightAlpha: 1.0, darkAlpha: 0.4)

    // Text
    static let text       = dyn(light: 0x18181B, dark: 0xE4E4E7)
    static let textDim    = dyn(light: 0x52525B, dark: 0xA1A1AA)
    static let textFaint  = dyn(light: 0x71717A, dark: 0x71717A)
    static let textGhost  = dyn(light: 0xA1A1AA, dark: 0x52525B)

    // Selection
    static let selection  = dyn(light: 0x06B6D4, dark: 0x0E7490, lightAlpha: 0.16, darkAlpha: 0.30)

    /// The app's own accent — deliberately not any agent vendor's colour.
    static let brand      = dyn(light: 0x4F46E5, dark: 0x6366F1)

    // Roles — user speaks in a bubble, the agent speaks on the page.
    static let userBubble = dyn(light: 0x4F46E5, dark: 0x4338CA)
    static let userLabel  = dyn(light: 0x4F46E5, dark: 0xA5B4FC)

    // Per-agent identity. Used only to label which agent produced a session,
    // never as the app's own branding.
    static let claude     = dyn(light: 0xC2542D, dark: 0xD97757)
    static let claudeSoft = dyn(light: 0xC2542D, dark: 0xD97757, lightAlpha: 0.28, darkAlpha: 0.35)

    // Semantic chips
    static let tool       = dyn(light: 0x475569, dark: 0x64748B)
    static let result     = dyn(light: 0x0D9488, dark: 0x14B8A6)
    static let error      = dyn(light: 0xE11D48, dark: 0xF43F5E)
    static let thinking   = dyn(light: 0xD97706, dark: 0xF59E0B)

    // Fonts
    static func monoFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Adaptive colour factory

    private static func dyn(
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

// MARK: - Hex helpers

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >>  8) & 0xFF) / 255,
            blue:    CGFloat( hex        & 0xFF) / 255,
            alpha:   alpha
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
