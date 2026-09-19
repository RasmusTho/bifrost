import SwiftUI
import UIKit

private enum YggColorRole {
    case background, surface, raised, overlay
    case primaryText, secondaryText, divider, focus
    case provenance, agent, active, healthy, pending, destructive
}

/// Yggdrasil's shared design tokens. The shell and every hosted client
/// (Mimer-iPhone today; Heimdal, Mimer-iPad later) draw from this one
/// palette/type-scale/spacing set so a hosted client never has to invent its
/// own chrome.
enum YggTheme {
    enum Color {
        /// Native semantic translation of the canonical Yggdrasil palette.
        /// The dark values match the handoff; light values retain the same
        /// semantic roles and preserve readable contrast in system light mode.
        static let background = color(.background)
        static let secondaryBackground = color(.surface)
        static let tertiaryBackground = color(.raised)
        static let overlay = color(.overlay)
        static let accent = color(.provenance)
        static let agent = color(.agent)
        static let active = color(.active)
        static let focus = color(.focus)
        static let textPrimary = color(.primaryText)
        static let textSecondary = color(.secondaryText)
        static let divider = color(.divider)
        static let warning = color(.pending)
        static let success = color(.healthy)
        static let destructive = color(.destructive)

        private static func color(_ role: YggColorRole) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { traits in
                resolvedUIColor(for: role, traitCollection: traits)
            })
        }

        private static func resolvedUIColor(
            for role: YggColorRole,
            traitCollection: UITraitCollection
        ) -> UIColor {
            let isDark = traitCollection.userInterfaceStyle == .dark
            switch role {
            case .background, .surface, .raised, .overlay:
                return backgroundUIColor(for: role, isDark: isDark)
            case .primaryText, .secondaryText, .divider, .focus:
                return foregroundUIColor(for: role, isDark: isDark)
            case .provenance, .agent, .active, .healthy, .pending, .destructive:
                return semanticUIColor(for: role, isDark: isDark)
            }
        }

        private static func backgroundUIColor(for role: YggColorRole, isDark: Bool) -> UIColor {
            switch role {
            case .background: return hex(isDark ? 0x070B12 : 0xF5F7FA)
            case .surface: return hex(isDark ? 0x0C1220 : 0xFFFFFF)
            case .raised: return hex(isDark ? 0x111A2E : 0xE9EEF5)
            case .overlay: return hex(isDark ? 0x162038 : 0xDCE5F0)
            default: return hex(0x000000)
            }
        }

        private static func foregroundUIColor(for role: YggColorRole, isDark: Bool) -> UIColor {
            switch role {
            case .primaryText: return hex(isDark ? 0xDCE8F0 : 0x102033)
            case .secondaryText: return hex(isDark ? 0x7A9AB8 : 0x48647D)
            case .divider: return hex(isDark ? 0x152030 : 0xBDCAD8)
            case .focus: return hex(0x00D4E8)
            default: return hex(0x000000)
            }
        }

        private static func semanticUIColor(for role: YggColorRole, isDark: Bool) -> UIColor {
            switch role {
            case .provenance: return hex(isDark ? 0xD4A843 : 0x8A5D00)
            case .agent: return hex(isDark ? 0x4A9EFF : 0x145CA8)
            case .active: return hex(0x00D4E8)
            case .healthy: return hex(isDark ? 0x39E87D : 0x087A3D)
            case .pending: return hex(isDark ? 0xF09030 : 0xA45400)
            case .destructive: return hex(isDark ? 0xFF3D3D : 0xB00020)
            default: return hex(0x000000)
            }
        }

        private static func hex(_ value: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let smd: CGFloat = 12
        static let md: CGFloat = 16
        static let mdl: CGFloat = 20
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 10
    }

    enum Typography {
        /// System serif marks the record's moments; UI chrome stays system
        /// sans and metadata stays monospaced, preserving Dynamic Type.
        static let title = Font.system(.title2, design: .serif).weight(.medium)
        static let sectionHeader = Font.system(.headline, design: .serif).weight(.medium)
        static let body = Font.body
        static let caption = Font.caption
        static let monospaceBody = Font.system(.body, design: .monospaced)
        static let monospaceCaption = Font.system(.caption, design: .monospaced)
    }
}
