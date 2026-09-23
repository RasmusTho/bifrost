import SwiftUI
import UIKit
import XCTest
@testable import Yggdrasil

/// YDS-05 (#70): YggTheme resolves to the pinned Yggdrasil Dark tokens.
final class YggThemeTokenBindingTests: XCTestCase {
    private func hex(_ color: SwiftUI.Color) -> UInt32 {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let channel = { (value: CGFloat) in UInt32((value * 255).rounded()) }
        return (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }

    func testColorsResolveToYggdrasilDarkTokens() {
        XCTAssertEqual(hex(YggTheme.Color.accent), 0xD4A843)
        XCTAssertEqual(hex(YggTheme.Color.background), 0x070B12)
        XCTAssertEqual(hex(YggTheme.Color.secondaryBackground), 0x0C1220)
        XCTAssertEqual(hex(YggTheme.Color.tertiaryBackground), 0x111A2E)
        XCTAssertEqual(hex(YggTheme.Color.textPrimary), 0xDCE8F0)
        XCTAssertEqual(hex(YggTheme.Color.textSecondary), 0x7A9AB8)
        XCTAssertEqual(hex(YggTheme.Color.warning), 0xF09030)
        XCTAssertEqual(hex(YggTheme.Color.success), 0x39E87D)
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

    func testVendoredTokensCarryThePinnedVersion() {
        XCTAssertEqual(YggdrasilTokens.version, "2.0.0")
    }
}
