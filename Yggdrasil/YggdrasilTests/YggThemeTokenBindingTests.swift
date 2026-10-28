import SwiftUI
import UIKit
import XCTest
@testable import Yggdrasil

/// YggTheme roles resolve to the pinned Yggdrasil tokens: Dark under the dark
/// user-interface style, Yggdrasil Light "Shell" under the light style.
final class YggThemeTokenBindingTests: XCTestCase {
    private func hex(_ color: SwiftUI.Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let channel = { (value: CGFloat) in UInt32((value * 255).rounded()) }
        return (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }

    func testColorsResolveToYggdrasilDarkTokens() {
        XCTAssertEqual(hex(YggTheme.Color.accent, .dark), 0xD4A843)
        XCTAssertEqual(hex(YggTheme.Color.background, .dark), 0x070B12)
        XCTAssertEqual(hex(YggTheme.Color.secondaryBackground, .dark), 0x0C1220)
        XCTAssertEqual(hex(YggTheme.Color.tertiaryBackground, .dark), 0x111A2E)
        XCTAssertEqual(hex(YggTheme.Color.textPrimary, .dark), 0xDCE8F0)
        XCTAssertEqual(hex(YggTheme.Color.textSecondary, .dark), 0x7A9AB8)
        XCTAssertEqual(hex(YggTheme.Color.warning, .dark), 0xF09030)
        XCTAssertEqual(hex(YggTheme.Color.success, .dark), 0x39E87D)
        XCTAssertEqual(hex(YggTheme.Color.destructive, .dark), 0xFF3D3D)
    }

    func testColorsResolveToYggdrasilShellTokens() {
        XCTAssertEqual(hex(YggTheme.Color.accent, .light), 0x573E00)
        XCTAssertEqual(hex(YggTheme.Color.background, .light), 0xE4E6EB)
        XCTAssertEqual(hex(YggTheme.Color.secondaryBackground, .light), 0xF1F2F5)
        XCTAssertEqual(hex(YggTheme.Color.tertiaryBackground, .light), 0xFFFFFF)
        XCTAssertEqual(hex(YggTheme.Color.textPrimary, .light), 0x0F1014)
        XCTAssertEqual(hex(YggTheme.Color.textSecondary, .light), 0x3F424A)
        XCTAssertEqual(hex(YggTheme.Color.warning, .light), 0x6A3400)
        XCTAssertEqual(hex(YggTheme.Color.success, .light), 0x094D29)
        XCTAssertEqual(hex(YggTheme.Color.destructive, .light), 0x841021)
        XCTAssertEqual(hex(YggTheme.Color.primaryFill, .light), 0x0F1014)
    }

    /// The semantic roles are names for canonical tokens, not a second palette:
    /// each resolves to the pinned Dark value under dark and the Shell value
    /// under light, and every state tone draws only from those roles.
    func testSemanticRolesResolveForBothColorSchemes() {
        struct Role {
            let name: String
            let color: SwiftUI.Color
            let dark: UInt32
            let shell: UInt32

            init(_ name: String, _ color: SwiftUI.Color, _ dark: UInt32, _ shell: UInt32) {
                (self.name, self.color, self.dark, self.shell) = (name, color, dark, shell)
            }
        }
        let roles: [Role] = [
            Role("background", YggTheme.Color.background, 0x070B12, 0xE4E6EB),
            Role("surface", YggTheme.Color.surface, 0x0C1220, 0xF1F2F5),
            Role("border", YggTheme.Color.border, 0x152030, 0xD3D6DC),
            Role("focus", YggTheme.Color.focus, 0x00D4E8, 0x007F8C),
            Role("provenance", YggTheme.Color.provenance, 0x4A9EFF, 0x1A3999),
            Role("pending", YggTheme.Color.pending, 0xF09030, 0x6A3400),
            Role("healthy", YggTheme.Color.healthy, 0x39E87D, 0x094D29),
            Role("failure", YggTheme.Color.failure, 0xFF3D3D, 0x841021),
            Role("provenanceMark", YggTheme.Color.provenanceMark, 0x4A9EFF, 0x2F6BFF),
            Role("pendingMark", YggTheme.Color.pendingMark, 0xF09030, 0xFF8A1A),
            Role("healthyMark", YggTheme.Color.healthyMark, 0x39E87D, 0x16C95E),
            Role("failureMark", YggTheme.Color.failureMark, 0xFF3D3D, 0xFF1F4B)
        ]
        for role in roles {
            XCTAssertEqual(hex(role.color, .dark), role.dark, "\(role.name) under Yggdrasil Dark")
            XCTAssertEqual(hex(role.color, .light), role.shell, "\(role.name) under Yggdrasil Light Shell")
        }

        let canonicalInk: [YggStateTone: SwiftUI.Color] = [
            .empty: YggTheme.Color.textSecondary,
            .pending: YggTheme.Color.pending,
            .healthy: YggTheme.Color.healthy,
            .attention: YggTheme.Color.warning,
            .failure: YggTheme.Color.failure,
            .provenance: YggTheme.Color.provenance
        ]
        XCTAssertEqual(Set(canonicalInk.keys), Set(YggStateTone.allCases))
        for tone in YggStateTone.allCases {
            let expected = canonicalInk[tone] ?? .clear
            for style in [UIUserInterfaceStyle.dark, .light] {
                XCTAssertEqual(hex(tone.ink, style), hex(expected, style), "\(tone) ink, style \(style.rawValue)")
            }
        }
        let spoken = YggStateTone.allCases.map(\.accessibilityLabel)
        XCTAssertEqual(Set(spoken).count, spoken.count, "Tones that share a colour must still be told apart.")
        let glyphs = YggStateTone.allCases.map(\.systemImage)
        XCTAssertEqual(Set(glyphs).count, glyphs.count)
    }

    func testSpacingAndRadiusResolveToYggdrasilTokens() {
        XCTAssertEqual(YggTheme.Spacing.xs, 4)
        XCTAssertEqual(YggTheme.Spacing.sm, 8)
        XCTAssertEqual(YggTheme.Spacing.md, 16)
        XCTAssertEqual(YggTheme.Spacing.lg, 24)
        XCTAssertEqual(YggTheme.Spacing.xl, 32)
        XCTAssertEqual(YggTheme.Radius.card, 10)
        XCTAssertEqual(YggTheme.Radius.control, 6)
    }

    func testAppearanceDefaultsToDarkAndMapsToColorSchemes() {
        XCTAssertEqual(YggAppearance(storedValue: nil), .dark)
        XCTAssertEqual(YggAppearance(storedValue: "bogus"), .dark)
        XCTAssertEqual(YggAppearance(storedValue: "shell"), .shell)
        XCTAssertEqual(YggAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(YggAppearance.shell.colorScheme, .light)
        XCTAssertNil(YggAppearance.system.colorScheme)
    }

    func testBundledYggdrasilFacesRegister() {
        YggFonts.register()
        for name in [
            YggFonts.uiLight, YggFonts.uiRegular, YggFonts.uiMedium, YggFonts.uiSemiBold,
            YggFonts.displayRegular, YggFonts.displayItalic, YggFonts.monoRegular, YggFonts.monoMedium
        ] {
            XCTAssertNotNil(UIFont(name: name, size: 17), "missing bundled face \(name)")
        }
    }

    func testVendoredTokensCarryThePinnedVersion() {
        XCTAssertEqual(YggdrasilTokens.version, "2.2.1")
    }
}
