import XCTest
import UIKit

final class MimerCanvasUITests: XCTestCase {
    func testIPadShowsThreeColumnCanvasWithAllLenses() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchMimerShell(withFixture: true)

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

        let sidebar = app.descendants(matching: .any)["mimer.canvas.focus.sidebar"]
        let content = app.descendants(matching: .any)["mimer.canvas.content.vault"]
        let detail = app.descendants(matching: .any)["mimer.canvas.detail"]
        assertAccessibilityValue("focused", for: content)
        app.typeKey(.leftArrow, modifierFlags: [])
        assertAccessibilityValue("focused", for: sidebar)
        app.typeKey(.tab, modifierFlags: [])
        assertAccessibilityValue("focused", for: content)
        app.typeKey(.rightArrow, modifierFlags: [])
        assertAccessibilityValue("focused", for: detail)

        let inspector = app.descendants(matching: .any)["mimer.canvas.inspector"]
        XCTAssertTrue(inspector.exists)
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)
        let filter = app.textFields["mimer.canvas.vault.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        assertAccessibilityValue("focused", for: filter)

        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 5))
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
    }

    func testBrowseFolderToNoteAcrossColumns() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell(withFixture: true)

        let vaultLens = app.descendants(matching: .any)["mimer.canvas.lens.vault"]
        XCTAssertTrue(vaultLens.waitForExistence(timeout: 10))
        vaultLens.tap()
        let projects = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.tap()

        let note = app.descendants(matching: .any)["mimer.canvas.vault.entry.Projects/fixture.md"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        XCTAssertTrue(app.staticTexts["Fixture note"].waitForExistence(timeout: 5))
        let uuid = app.descendants(matching: .any)["mimer.canvas.inspector.uuid"]
        XCTAssertTrue(uuid.waitForExistence(timeout: 5))
        XCTAssertTrue(uuid.label.contains("fixture-uuid"))
    }

    private func assertAccessibilityValue(
        _ expectedValue: String,
        for element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Expected accessibility value \(expectedValue), got \(String(describing: element.value)).",
            file: file,
            line: line
        )
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
