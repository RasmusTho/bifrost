import XCTest
import UIKit

final class MimerCanvasUITests: XCTestCase {
    func testIPadShowsThreeColumnCanvasWithAllLenses() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchMimerShell()

        XCTAssertTrue(app.navigationBars["Mimer"].waitForExistence(timeout: 10))
        for lens in ["today", "interests", "entities", "consent", "vault", "settings"] {
            let sidebarLens = app.descendants(matching: .any)["mimer.canvas.lens.\(lens)"]
            XCTAssertTrue(
                sidebarLens.waitForExistence(timeout: 5),
                "Expected the \(lens) lens in the iPad canvas sidebar."
            )
            sidebarLens.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["mimer.canvas.content.\(lens)"].waitForExistence(timeout: 5),
                "Expected selecting \(lens) to present its content column."
            )
        }
        XCTAssertTrue(app.descendants(matching: .any)["mimer.canvas.detail"].exists)
    }

    func testIPhoneKeepsTabBar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only tab verification")
        let app = launchMimerShell()

        XCTAssertTrue(app.otherElements["mimer.compact.tabView"].waitForExistence(timeout: 10))
        for tab in ["Today", "Interests", "Entities", "Consent"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "Expected the shipped \(tab) tab.")
        }
        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(moreTab.exists, "Expected the shipped overflow tab.")
        moreTab.tap()
        for overflowTab in ["Vault", "Settings"] {
            XCTAssertTrue(
                app.staticTexts[overflowTab].waitForExistence(timeout: 5),
                "Expected the shipped \(overflowTab) tab in More."
            )
        }
        XCTAssertFalse(app.descendants(matching: .any)["mimer.canvas.lens.today"].exists)
    }

    func testKeyboardColumnTraversalAndInspectorToggle() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell()

        let vaultLens = app.descendants(matching: .any)["mimer.canvas.lens.vault"]
        XCTAssertTrue(vaultLens.waitForExistence(timeout: 10))
        vaultLens.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mimer.canvas.content.vault"].waitForExistence(timeout: 5))

        let inspector = app.buttons["mimer.canvas.inspector.toggle"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mimer.canvas.inspector"].exists)
        app.typeKey("i", modifierFlags: .command)
        XCTAssertFalse(app.descendants(matching: .any)["mimer.canvas.inspector"].exists)
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["mimer.canvas.inspector"].waitForExistence(timeout: 5))
    }

    func testBrowseFolderToNoteAcrossColumns() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell(withFixture: true)

        app.descendants(matching: .any)["mimer.canvas.lens.vault"].tap()
        let projects = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()

        let note = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/fixture.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(app.staticTexts["Fixture note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture-uuid"].waitForExistence(timeout: 5))
    }

    private func launchMimerShell(withFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing-auth-unlocked", "-ui-testing-mimer-shell"]
        if withFixture {
            app.launchArguments.append("-ui-testing-mimer-fixture")
        }
        app.launch()
        return app
    }
}
