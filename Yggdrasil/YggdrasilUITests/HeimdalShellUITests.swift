import XCTest

final class HeimdalShellUITests: XCTestCase {
    func testHeimdalAreaReachable() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-auth-unlocked")
        app.launch()

        // Floating iPad tab bars can expose items as cells or other elements,
        // while compact tab bars expose buttons. Select by the stable label so
        // the same reachability assertion runs against either accessibility tree.
        let heimdalTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Heimdal"))
            .firstMatch
        XCTAssertTrue(heimdalTab.waitForExistence(timeout: 10))
        heimdalTab.tap()
        XCTAssertTrue(app.navigationBars["Heimdal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["heimdal.chooseCaptureFolder"].exists)
        XCTAssertTrue(app.buttons["heimdal.record.disabled"].exists)
    }
}
