import SwiftUI

/// Yggdrasil's shared design tokens. The shell and every hosted client
/// (Mimer-iPhone today; Heimdal, Mimer-iPad later) draw from this one
/// palette/type-scale/spacing set so a hosted client never has to invent its
/// own chrome.
enum YggTheme {
    enum Color {
        /// Native semantic translation of `colors_and_type.css`. The dark
        /// values intentionally match the canonical Yggdrasil token sheet;
        /// light values preserve the same semantic contrast roles for Apple
        /// platform accessibility rather than inventing a second vocabulary.
        enum SemanticRole: CaseIterable {
            case background, surface, raised, overlay
            case primaryText, secondaryText, divider, focus
            case provenance, active, healthy, pending, destructive
        }

        static let background = color(.background)
        static let secondaryBackground = color(.surface)
        static let tertiaryBackground = color(.raised)
        static let overlay = color(.overlay)
        static let accent = color(.provenance)
        static let textPrimary = color(.primaryText)
        static let textSecondary = color(.secondaryText)
        static let divider = color(.divider)
        static let focus = color(.focus)
        static let active = color(.active)
        static let warning = color(.pending)
        static let success = color(.healthy)
        static let destructive = color(.destructive)

        static func color(_ role: SemanticRole) -> SwiftUI.Color {
            SwiftUI.Color(uiColor: UIColor { traits in
                resolvedUIColor(for: role, traitCollection: traits)
            })
        }

        static func resolvedUIColor(
            for role: SemanticRole,
            traitCollection: UITraitCollection
        ) -> UIColor {
            let isDark = traitCollection.userInterfaceStyle == .dark
            switch role {
            case .background: hex(isDark ? 0x070B12 : 0xF5F7FA)
            case .surface: hex(isDark ? 0x0C1220 : 0xFFFFFF)
            case .raised: hex(isDark ? 0x111A2E : 0xE9EEF5)
            case .overlay: hex(isDark ? 0x162038 : 0xDCE5F0)
            case .primaryText: hex(isDark ? 0xDCE8F0 : 0x102033)
            case .secondaryText: hex(isDark ? 0x7A9AB8 : 0x48647D)
            case .divider: hex(isDark ? 0x152030 : 0xBDCAD8)
            case .focus: hex(0x00D4E8)
            case .provenance: hex(0xD4A843)
            case .active: hex(0x00D4E8)
            case .healthy: hex(0x39E87D)
            case .pending: hex(0xF09030)
            case .destructive: hex(0xFF3D3D)
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
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 6
        static let control: CGFloat = 4
    }

    enum Typography {
        /// System serif, system UI and system mono preserve the canonical
        /// display/UI/evidence roles without shipping web-font assets in a
        /// native app.
        static let title = Font.system(.title2, design: .serif).weight(.medium)
        static let sectionHeader = Font.system(.title3, design: .serif).weight(.medium)
        static let body = Font.body
        static let caption = Font.caption
        static let monospaceBody = Font.system(.body, design: .monospaced)
    }
}
