import SwiftUI

/// Pulli's colour themes. Porcelain is the default (owner's choice, 2026-10-14). `classic` is the original look (a colour scene per section, candy
/// art); the others use one calm background for the whole app, one accent, and quieter art.
///
/// Read from a global because colours are needed in places with no SwiftUI environment (3D
/// materials, rendered images). Changing it means redrawing the window.
enum AppTheme: String, CaseIterable, Sendable {
    case classic, graphite, midnight, porcelain

    nonisolated(unsafe) static var current: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .porcelain

    var title: String {
        switch self {
        case .classic: "Classic"
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .porcelain: "Porcelain"
        }
    }

    var accent: Color {
        switch self {
        case .classic: Color(hex: 0x3CCFBE)
        case .graphite: Color(hex: 0x4A86FF)
        case .midnight: Color(hex: 0x8B7CF6)
        case .porcelain: Color(hex: 0x3557E0)
        }
    }

    var accentDeep: Color {
        switch self {
        case .classic: Color(hex: 0x0A6F66)
        case .graphite: Color(hex: 0x1F4FCF)
        case .midnight: Color(hex: 0x4B36C9)
        case .porcelain: Color(hex: 0x1C35A8)
        }
    }

    /// Links on dark and light backgrounds.
    func link(dark: Bool) -> Color {
        switch self {
        case .classic: dark ? Color(hex: 0x8FE6DB) : Color(hex: 0x0A7A6D)
        case .graphite: dark ? Color(hex: 0x8FB4FF) : Color(hex: 0x1F4FCF)
        case .midnight: dark ? Color(hex: 0xBCB2FF) : Color(hex: 0x4B36C9)
        case .porcelain: dark ? Color(hex: 0x9DB0FF) : Color(hex: 0x2443C2)
        }
    }

    /// Dark text on light backgrounds.
    var ink: UInt32 {
        switch self {
        case .classic: 0x0B1D26
        case .graphite: 0x16181C
        case .midnight: 0x16143A
        case .porcelain: 0x1A1A1F
        }
    }

    /// One background for every screen (nil: the classic colour scene per section).
    func scene(dark: Bool) -> SceneKind.Recipe? {
        switch (self, dark) {
        case (.classic, _):
            return nil
        case (.graphite, true):
            return SceneKind.Recipe(base: [Color(hex: 0x141518), Color(hex: 0x1B1D21), Color(hex: 0x15171B)],
                                    glowA: Color(hex: 0x4A86FF, opacity: 0.10), glowB: Color(hex: 0xFFFFFF, opacity: 0.05),
                                    centerA: UnitPoint(x: 0.85, y: 0.0), centerB: UnitPoint(x: 0.1, y: 1.0))
        case (.graphite, false):
            return SceneKind.Recipe(base: [Color(hex: 0xF6F5F2), Color(hex: 0xEEEDEA), Color(hex: 0xE8E8E6)],
                                    glowA: Color(hex: 0xFFFFFF, opacity: 0.7), glowB: Color(hex: 0x4A86FF, opacity: 0.06),
                                    centerA: UnitPoint(x: 0.85, y: 0.0), centerB: UnitPoint(x: 0.1, y: 1.0))
        case (.midnight, true):
            return SceneKind.Recipe(base: [Color(hex: 0x0D1030), Color(hex: 0x171A45), Color(hex: 0x1E1B4B)],
                                    glowA: Color(hex: 0x8B7CF6, opacity: 0.32), glowB: Color(hex: 0x3B5BDB, opacity: 0.26),
                                    centerA: UnitPoint(x: 0.82, y: 0.05), centerB: UnitPoint(x: 0.08, y: 0.98))
        case (.midnight, false):
            return SceneKind.Recipe(base: [Color(hex: 0xF1F0FB), Color(hex: 0xE6E4F8), Color(hex: 0xDEE2F7)],
                                    glowA: Color(hex: 0x8B7CF6, opacity: 0.20), glowB: Color(hex: 0x6A86F0, opacity: 0.16),
                                    centerA: UnitPoint(x: 0.82, y: 0.05), centerB: UnitPoint(x: 0.08, y: 0.98))
        case (.porcelain, true):
            return SceneKind.Recipe(base: [Color(hex: 0x1C1C1F), Color(hex: 0x222226), Color(hex: 0x1D1D21)],
                                    glowA: Color(hex: 0xFFFFFF, opacity: 0.05), glowB: Color(hex: 0x3557E0, opacity: 0.08),
                                    centerA: UnitPoint(x: 0.85, y: 0.0), centerB: UnitPoint(x: 0.1, y: 1.0))
        case (.porcelain, false):
            return SceneKind.Recipe(base: [Color(hex: 0xFBFAF8), Color(hex: 0xF5F3EF), Color(hex: 0xF1EFEA)],
                                    glowA: Color(hex: 0xFFFFFF, opacity: 0.9), glowB: Color(hex: 0xE9E4DA, opacity: 0.5),
                                    centerA: UnitPoint(x: 0.85, y: 0.0), centerB: UnitPoint(x: 0.1, y: 1.0))
        }
    }

    /// The art's colours: classic keeps each palette; the others pull every palette into the
    /// theme's family, keeping a hint of the original so items stay tellable apart.
    func colors(for original: [Color]) -> [Color] {
        func mix(_ base: UInt32, _ color: Color, _ amount: Double) -> Color { Color(hex: base).mix(with: color, by: amount) }
        switch self {
        case .classic:
            return original
        case .graphite:
            return [mix(0xE4E6EA, original[0], 0.10), mix(0x6B717C, original[1], 0.20), mix(0x24272D, original[2], 0.14)]
        case .midnight:
            return [mix(0xD9D3FF, original[0], 0.22), mix(0x6C5CE7, original[1], 0.24), mix(0x221B66, original[2], 0.20)]
        case .porcelain:
            return [Color(hex: 0xFFFFFF), mix(0xECE9E3, original[1], 0.08), mix(0xC2BDB3, original[2], 0.10)]
        }
    }

    /// The symbol on art: white, or (on white porcelain) the item's own colour; Pulli's own teal
    /// becomes the theme's ink blue.
    func symbolOnArt(_ palette: ArtPalette) -> Color {
        guard self == .porcelain else { return .white }
        if palette == .teal { return accentDeep }
        return palette.original[2].mix(with: Color(hex: 0x1A1A1F), by: 0.35)
    }
}
