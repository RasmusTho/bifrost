import SwiftUI

/// Yggdrasil's shared design tokens. The shell and every hosted client
/// (Mimer-iPhone today; Heimdal, Mimer-iPad later) draw from this one
/// palette/type-scale/spacing set so a hosted client never has to invent its
/// own chrome.
///
/// Colours, spacing, and radius come from the vendored, generated Yggdrasil
/// Design System v2 tokens (`YggdrasilTokens.generated.swift`), pinned to token
/// VERSION 2.0.0 at hub commit 0021e1374b84a0cd31dc00ea9f5647f1422a33fe
/// (RasmusTho/agentic-pkm-mvp, YDS-05 / #70). Never edit the vendored file; re-vendor
/// a newer hub commit and update the pin in `.github/workflows/ci.yml` instead.
/// Dark only until the hub's Yggdrasil Light "Shell" trial graduates.
enum YggTheme {
    enum Color {
        static let background = YggdrasilTokens.Dark.bgBase
        static let secondaryBackground = YggdrasilTokens.Dark.bgSurface
        static let tertiaryBackground = YggdrasilTokens.Dark.bgRaised
        static let accent = YggdrasilTokens.Dark.accent
        static let textPrimary = YggdrasilTokens.Dark.fg1
        static let textSecondary = YggdrasilTokens.Dark.fg2
        static let divider = YggdrasilTokens.Dark.borderStrong
        static let warning = YggdrasilTokens.Dark.amber
        static let success = YggdrasilTokens.Dark.vault
    }

    enum Spacing {
        static let xs = YggdrasilTokens.Spacing.space1
        static let sm = YggdrasilTokens.Spacing.space2
        static let md = YggdrasilTokens.Spacing.space4
        static let lg = YggdrasilTokens.Spacing.space6
        static let xl = YggdrasilTokens.Spacing.space8
    }

    enum Radius {
        static let card = YggdrasilTokens.Radius.radiusXl
        static let control = YggdrasilTokens.Radius.radiusLg
    }

    enum Typography {
        static let title = Font.title2.weight(.semibold)
        static let sectionHeader = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let monospaceBody = Font.system(.body, design: .monospaced)
    }
}
