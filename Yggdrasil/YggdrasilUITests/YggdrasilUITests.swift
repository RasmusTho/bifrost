import XCTest
import UIKit

final class YggdrasilUITests: XCTestCase {
    func testAuthGatePrecedesVaultContent() throws {
        try requireIPhone()
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-auth-locked"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["yggdrasil.authGate"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["mimer.compact.tabView"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["yggdrasil.vaultPicker"].exists)
    }

    func testVaultSelectionHasNoTextInput() throws {
        try requireIPhone()
        let app = launchVaultPicker()
        let picker = app.descendants(matching: .any)["yggdrasil.vaultPicker"]

        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.textFields.count, 0)
        XCTAssertEqual(picker.secureTextFields.count, 0)
        XCTAssertTrue(app.buttons["Choose a Vault Folder"].exists)
    }

    func testHeimdalNoteRenderEditRoundTrip() throws {
        try requireIPhone()
        let app = launchFixtureVault()
        openFixtureRoundTripNote(in: app)
        XCTAssertTrue(app.staticTexts["UAT fixture note"].waitForExistence(timeout: 5))

        app.buttons["Edit"].tap()
        let editor = app.textViews["yggdrasil.noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeKey(.end, modifierFlags: [])
        editor.typeText("\nSaved by XCUITest.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))

        // Relaunching and reopening edit mode forces a fresh disk read rather
        // than merely asserting the prior TextEditor's in-memory value.
        app.terminate()
        app.launch()
        openFixtureRoundTripNote(in: app)
        XCTAssertTrue(app.staticTexts["UAT fixture note"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        let reloadedEditor = app.textViews["yggdrasil.noteEditor"]
        XCTAssertTrue(reloadedEditor.waitForExistence(timeout: 5))
        XCTAssertTrue((reloadedEditor.value as? String)?.contains("Saved by XCUITest.") == true)
    }

    func testAllFiveLensesLoadFixtureNotes() throws {
        try requireIPhone()
        let app = launchFixtureVault()

        XCTAssertTrue(app.staticTexts["fixture_attention"].waitForExistence(timeout: 10))

        selectTab("Interests", in: app)
        XCTAssertTrue(app.staticTexts["fixture_interest"].waitForExistence(timeout: 5))

        selectTab("Entities", in: app)
        XCTAssertTrue(app.staticTexts["Fixture Entity"].waitForExistence(timeout: 5))

        selectTab("Consent", in: app)
        let consentLens = app.descendants(matching: .any)["mimer.lens.consent"]
        XCTAssertTrue(consentLens.waitForExistence(timeout: 5))
        XCTAssertTrue(consentLens.staticTexts["fixture consent"].exists)
        XCTAssertEqual(consentLens.textFields.count, 0)
        XCTAssertEqual(consentLens.textViews.count, 0)

        selectTab("Settings", in: app)
        XCTAssertTrue(app.staticTexts["Retention window: 45 days"].waitForExistence(timeout: 5))
    }

    private func launchVaultPicker() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-auth-unlocked"]
        app.launch()
        return app
    }

    private func requireIPhone() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "B1 acceptance journeys verify the iPhone Mimer tab surface; iPad canvas coverage is separate."
        )
    }

    private func launchFixtureVault() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-auth-unlocked",
            "-ui-testing-uat-fixture",
            UUID().uuidString
        ]
        app.launch()
        return app
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let directTab = app.tabBars.buttons[title]
        if directTab.exists {
            directTab.tap()
            return
        }

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 5), "Expected \(title) in the compact tab overflow.")
        moreTab.tap()
        let overflowTab = app.staticTexts[title]
        XCTAssertTrue(overflowTab.waitForExistence(timeout: 5), "Expected \(title) in More.")
        overflowTab.tap()
    }

    private func openFixtureRoundTripNote(in app: XCUIApplication) {
        selectTab("Vault", in: app)
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 10))
        app.buttons["_heimdal"].tap()
        app.buttons["uat-roundtrip.md"].tap()
    }
}
