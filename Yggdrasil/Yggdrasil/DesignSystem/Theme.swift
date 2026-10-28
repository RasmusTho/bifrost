import SwiftUI
import CoreText
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

        // Semantic state roles (hub `docs/YGGDRASIL_DESIGN_SYSTEM_V2` domain
        // meaning). These are names for existing tokens, never new colours:
        // `surface` is `bg-surface`, `provenance` is `agent` (agent-contributed),
        // `pending` is `amber` (staged / uncommitted), `healthy` is `vault`
        // (vault-connected / committed), and `failure` is `destructive`.
        static let surface = secondaryBackground
        static let provenance = agent
        static let pending = warning
        static let healthy = vault
        static let failure = destructive
        static let provenanceMark = role(
            dark: YggdrasilTokens.Dark.agentMark, shell: YggdrasilTokens.Shell.agentMark
        )
        static let pendingMark = warningMark
        static let healthyMark = role(
            dark: YggdrasilTokens.Dark.vaultMark, shell: YggdrasilTokens.Shell.vaultMark
        )
        static let failureMark = destructiveMark

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

    /// The Yggdrasil type core, the same faces as the web (`--font-ui`
    /// Space Grotesk, `--font-display` EB Garamond, `--font-mono` JetBrains
    /// Mono), bundled under Resources/Fonts (SIL OFL 1.1, FONTS-OFL.txt) and
    /// scaled with Dynamic Type through `relativeTo:`.
    enum Typography {
        static let title = Font.custom(YggFonts.uiMedium, size: 22, relativeTo: .title2)
        /// Secondary display lines (EB Garamond italic on the web).
        static let display = Font.custom(YggFonts.displayItalic, size: 28, relativeTo: .title)
        static let sectionHeader = Font.custom(YggFonts.uiMedium, size: 17, relativeTo: .headline)
        static let body = Font.custom(YggFonts.uiRegular, size: 17, relativeTo: .body)
        static let bodyEmphasis = Font.custom(YggFonts.uiMedium, size: 17, relativeTo: .body)
        static let caption = Font.custom(YggFonts.uiRegular, size: 12, relativeTo: .caption)
        static let monospaceBody = Font.custom(YggFonts.monoRegular, size: 15, relativeTo: .body)
        /// Status labels: uppercase tracked mono.
        static let statusLabel = Font.custom(YggFonts.monoMedium, size: 11, relativeTo: .caption2)

        /// Markdown headings: H1 in light tracked display weight, then medium.
        static func heading(level: Int) -> Font {
            switch level {
            case 1: Font.custom(YggFonts.uiLight, size: 28, relativeTo: .title)
            case 2: Font.custom(YggFonts.uiMedium, size: 22, relativeTo: .title2)
            case 3: Font.custom(YggFonts.uiMedium, size: 20, relativeTo: .title3)
            default: sectionHeader
            }
        }
    }
}

/// PostScript names of the bundled faces, and their one-time registration.
enum YggFonts {
    static let uiLight = "SpaceGrotesk-Light"
    static let uiRegular = "SpaceGrotesk-Regular"
    static let uiMedium = "SpaceGrotesk-Medium"
    static let uiSemiBold = "SpaceGrotesk-SemiBold"
    static let displayRegular = "EBGaramond-Regular"
    static let displayItalic = "EBGaramond-Italic"
    static let monoRegular = "JetBrainsMono-Regular"
    static let monoMedium = "JetBrainsMono-Medium"

    /// Registers every bundled `.ttf` for this process (no Info.plist
    /// `UIAppFonts` entry needed). Safe to call more than once.
    static func register(bundle: Bundle = .main) {
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
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

    /// Navigation titles in the Yggdrasil type: Space Grotesk, light and
    /// widely tracked for large titles, like the web display headings. Shell
    /// adds the cyan half of the chromatic split. SwiftUI has no
    /// navigation-title font API, so this uses the UIKit appearance proxy.
    /// Call once at launch, after `YggFonts.register()`.
    static func configureNavigationTitles() {
        let split = NSShadow()
        split.shadowColor = UIColor { traits in
            traits.userInterfaceStyle == .light ? UIColor(YggTheme.Material.splitCyan) : .clear
        }
        split.shadowOffset = CGSize(width: -1.5, height: 0)
        split.shadowBlurRadius = 0
        let ink = UIColor(YggTheme.Color.textPrimary)
        let bar = UINavigationBar.appearance()
        if let large = UIFont(name: YggFonts.uiLight, size: 30) {
            bar.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large),
                .kern: 3.6,
                .foregroundColor: ink,
                .shadow: split
            ]
        }
        if let inline = UIFont(name: YggFonts.uiMedium, size: 15) {
            bar.titleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline),
                .kern: 1.5,
                .foregroundColor: ink
            ]
        }
    }

    /// Unknown stored values fall back to Dark, like the web `data-theme` grammar.
    init(storedValue: String?) {
        self = storedValue.flatMap(YggAppearance.init(rawValue:)) ?? YggAppearance.defaultValue
    }
}
