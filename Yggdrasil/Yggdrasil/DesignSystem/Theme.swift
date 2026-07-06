import SwiftUI

/// Yggdrasil's shared design tokens. The shell and every hosted client
/// (Mimer-iPhone today; Heimdal, Mimer-iPad later) draw from this one
/// palette/type-scale/spacing set so a hosted client never has to invent its
/// own chrome.
enum YggTheme {
    enum Color {
        static let background = SwiftUI.Color(.systemBackground)
        static let secondaryBackground = SwiftUI.Color(.secondarySystemBackground)
        static let tertiaryBackground = SwiftUI.Color(.tertiarySystemBackground)
        static let accent = SwiftUI.Color.accentColor
        static let textPrimary = SwiftUI.Color.primary
        static let textSecondary = SwiftUI.Color.secondary
        static let divider = SwiftUI.Color(.separator)
        static let warning = SwiftUI.Color.orange
        static let success = SwiftUI.Color.green
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 10
    }

    enum Typography {
        static let title = Font.title2.weight(.semibold)
        static let sectionHeader = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let monospaceBody = Font.system(.body, design: .monospaced)
    }
}
