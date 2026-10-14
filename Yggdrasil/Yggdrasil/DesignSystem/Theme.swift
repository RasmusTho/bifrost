import SwiftUI
import UIKit

/// Yggdrasil's shared design tokens. The shell and every hosted client
/// (Mimer, Heimdal) draw from this one palette/type-scale/spacing set so a
/// hosted client never has to invent its own chrome.
///
/// Colours, spacing, and radius come from the vendored, generated Yggdrasil
/// Design System v2 tokens (`YggdrasilTokens.generated.swift`), pinned to token
/// VERSION 2.2.1 at hub commit be8bebde4f26d70150bbfa1c27e0ca7015cef4f5
/// (RasmusTho/agentic-pkm-mvp). Never edit the vendored file; re-vendor a newer
/// hub commit and update the pin in `.github/workflows/ci.yml` instead.
///
/// Two themes, one set of roles (hub `docs/YGGDRASIL_DESIGN_SYSTEM_V2`):
/// - **Yggdrasil Dark** — the default. Bound to the dark user-interface style.
/// - **Yggdrasil Light "Shell"** — porcelain surfaces on a neon night city
///   (Ghost in the Shell). Bound to the light user-interface style.
///
/// Every `YggTheme.Color` role is a dynamic colour that resolves against the
/// view's trait collection, so call sites never branch on theme. The theme is
/// chosen by `YggAppearance` (Dark / Shell / System) and applied once at the app
/// root through `preferredColorScheme`.
enum YggTheme {
    enum Color {
        // Surfaces and text.
        static let background = role(dark: YggdrasilTokens.Dark.bgBase, shell: YggdrasilTokens.Shell.bgBase)
        static let secondaryBackground = role(
            dark: YggdrasilTokens.Dark.bgSurface, shell: YggdrasilTokens.Shell.bgSurface
        )
        static let tertiaryBackground = role(
            dark: YggdrasilTokens.Dark.bgRaised, shell: YggdrasilTokens.Shell.bgRaised
        )
        static let textPrimary = role(dark: YggdrasilTokens.Dark.fg1, shell: YggdrasilTokens.Shell.fg1)
        static let textSecondary = role(dark: YggdrasilTokens.Dark.fg2, shell: YggdrasilTokens.Shell.fg2)
        /// Disabled / decorative only — never readable content (v2 contrast rule).
        static let textDisabled = role(dark: YggdrasilTokens.Dark.fg3, shell: YggdrasilTokens.Shell.fg3)
        static let border = role(dark: YggdrasilTokens.Dark.border, shell: YggdrasilTokens.Shell.border)
        static let divider = role(
            dark: YggdrasilTokens.Dark.borderStrong, shell: YggdrasilTokens.Shell.border
        )
        static let focus = role(
            dark: YggdrasilTokens.Dark.borderFocus, shell: YggdrasilTokens.Shell.borderFocus
        )

        // Brand and domain meaning (ink tones: safe for text in both themes).
        static let accent = role(dark: YggdrasilTokens.Dark.accent, shell: YggdrasilTokens.Shell.accent)
        static let cyan = role(dark: YggdrasilTokens.Dark.cyan, shell: YggdrasilTokens.Shell.cyan)
        static let vault = role(dark: YggdrasilTokens.Dark.vault, shell: YggdrasilTokens.Shell.vault)
        static let agent = role(dark: YggdrasilTokens.Dark.agent, shell: YggdrasilTokens.Shell.agent)
        static let warning = role(dark: YggdrasilTokens.Dark.amber, shell: YggdrasilTokens.Shell.amber)
        static let success = vault
        static let destructive = role(
            dark: YggdrasilTokens.Dark.destructive, shell: YggdrasilTokens.Shell.destructive
        )

        // Mark tones: decorative markers next to ink text. Never text in Shell.
        static let accentMark = role(
            dark: YggdrasilTokens.Dark.accentMark, shell: YggdrasilTokens.Shell.accentMark
        )
        static let warningMark = role(
            dark: YggdrasilTokens.Dark.amberMark, shell: YggdrasilTokens.Shell.amberMark
        )
        static let destructiveMark = role(
            dark: YggdrasilTokens.Dark.destructiveMark, shell: YggdrasilTokens.Shell.destructiveMark
        )

        /// Primary-button fill: gold in Dark, solid graphite in Shell.
        static let primaryFill = role(dark: YggdrasilTokens.Dark.accent, shell: YggdrasilTokens.Shell.fg1)
        static let onPrimaryFill = role(
            dark: YggdrasilTokens.Dark.fgInverse, shell: YggdrasilTokens.Shell.fgInverse
        )

        /// One role, bound per theme through the trait collection.
        static func role(dark: SwiftUI.Color, shell: SwiftUI.Color) -> SwiftUI.Color {
            let darkColor = UIColor(dark)
            let shellColor = UIColor(shell)
            return SwiftUI.Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .light ? shellColor : darkColor
            })
        }
    }

    /// Shell material values from the hub's `tokens/css-values.json`
    /// (`.shell` block), mapped to SwiftUI. Dark has no material beyond its
    /// faint cyan grid.
    enum Material {
        /// Rim light: cyan from the left, red from the right.
        static let rimCyan = SwiftUI.Color(yggHex: 0x00E5FF, opacity: 0.9)
        static let rimRed = SwiftUI.Color(yggHex: 0xFF1F4B, opacity: 0.95)
        /// Chromatic split on titles and the primary button edge.
        static let splitCyan = SwiftUI.Color(yggHex: 0x00E5FF, opacity: 0.55)
        static let splitRed = SwiftUI.Color(yggHex: 0xFF1F4B, opacity: 0.55)
        /// Porcelain sheet gradient stops. The web sheet is 90 % → 85 % plus a
        /// backdrop blur; SwiftUI has no tunable backdrop blur, so the iOS sheet
        /// stays at the 75 % contrast floor the hub tests guard, letting the
        /// city glow through.
        static let sheetStops: [Gradient.Stop] = [
            .init(color: SwiftUI.Color(yggHex: 0xFFFFFF, opacity: 0.80), location: 0),
            .init(color: SwiftUI.Color(yggHex: 0xF1F2F5, opacity: 0.76), location: 0.45),
            .init(color: SwiftUI.Color(yggHex: 0xE4E6EB, opacity: 0.75), location: 1)
        ]
        /// Night-city base (`#150a2a` → `#06040c` → `#020104`).
        static let cityBase: [SwiftUI.Color] = [
            SwiftUI.Color(yggHex: 0x150A2A), SwiftUI.Color(yggHex: 0x06040C), SwiftUI.Color(yggHex: 0x020104)
        ]
        /// Neo-Tokyo palette (city set 1): red, cyan, magenta, blue.
        static let citySigns: [SwiftUI.Color] = [
            SwiftUI.Color(yggHex: 0xFF1F4B), SwiftUI.Color(yggHex: 0x00E5FF),
            SwiftUI.Color(yggHex: 0xFF2AA0), SwiftUI.Color(yggHex: 0x2850FF)
        ]
        /// Dark glass chrome over the city.
        static let glass = SwiftUI.Color(red: 10 / 255, green: 8 / 255, blue: 24 / 255, opacity: 0.74)
        /// Dark's backdrop grid line.
        static let darkGrid = SwiftUI.Color(yggHex: 0x00D4E8, opacity: 0.04)
        static let frameGap: CGFloat = 10
        static let shellPanelRadius: CGFloat = 2
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

    /// iOS Dynamic Type mapped onto Yggdrasil roles; `display` uses New York
    /// serif as the closest native analogue to EB Garamond.
    enum Typography {
        static let title = Font.title2.weight(.semibold)
        static let display = Font.system(.largeTitle, design: .serif).italic()
        static let sectionHeader = Font.headline
        static let body = Font.body
        static let caption = Font.caption
        static let monospaceBody = Font.system(.body, design: .monospaced)
        /// Shell status labels: uppercase tracked mono.
        static let statusLabel = Font.system(.caption2, design: .monospaced).weight(.medium)
    }
}

/// The owner's theme choice. Dark is the default; Shell is a supported,
/// per-user choice (graduated 2026-09-25); System follows the device.
/// This is a device-local display preference, like the Companion's
/// `companion.displayPreferences.v1` — it never writes to the vault.
enum YggAppearance: String, CaseIterable, Identifiable {
    case dark
    case shell
    case system

    static let storageKey = "yggdrasil.appearance.theme"
    static let defaultValue: YggAppearance = .dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Yggdrasil Dark"
        case .shell: "Yggdrasil Light \u{201C}Shell\u{201D}"
        case .system: "System"
        }
    }

    /// `nil` lets the device decide: Shell under light, Dark otherwise.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .shell: .light
        case .system: nil
        }
    }

    /// Shell display headings: light, widely tracked, with the cyan half of
    /// the chromatic split. SwiftUI has no navigation-title font API, so this
    /// goes through the UIKit appearance proxy, scoped to the light (Shell)
    /// trait so Yggdrasil Dark keeps the system titles. Call once at launch.
    static func configureShellNavigationTitles() {
        let split = NSShadow()
        split.shadowColor = UIColor(YggTheme.Material.splitCyan)
        split.shadowOffset = CGSize(width: -1.5, height: 0)
        split.shadowBlurRadius = 0
        let ink = UIColor(YggdrasilTokens.Shell.fg1)
        let bar = UINavigationBar.appearance(for: UITraitCollection(userInterfaceStyle: .light))
        bar.largeTitleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 30, weight: .light),
            .kern: 6,
            .foregroundColor: ink,
            .shadow: split
        ]
        bar.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 15, weight: .regular),
            .kern: 3,
            .foregroundColor: ink
        ]
    }

    /// Unknown stored values fall back to Dark, like the web `data-theme` grammar.
    init(storedValue: String?) {
        self = storedValue.flatMap(YggAppearance.init(rawValue:)) ?? YggAppearance.defaultValue
    }
}
