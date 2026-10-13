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

    func testVendoredTokensCarryThePinnedVersion() {
        XCTAssertEqual(YggdrasilTokens.version, "2.2.1")
    }
}
