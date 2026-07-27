import XCTest

final class HeimdalShellUITests: XCTestCase {
    func testHeimdalAreaReachable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-auth-unlocked"]
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
        XCTAssertTrue(app.buttons["heimdal.record"].exists)
    }

    func testConsentSurfaceStates() throws {
        let granted = launchHeimdal(arguments: [])
        XCTAssertTrue(granted.staticTexts["Standing grant: fixture consent"].waitForExistence(timeout: 5))
        XCTAssertTrue(granted.staticTexts["Not registered — captures may be refused"].exists)
        XCTAssertTrue(granted.buttons["heimdal.registration.register"].exists)

        granted.terminate()

        let missing = launchHeimdal(arguments: ["-ui-testing-no-consent"])
        XCTAssertTrue(missing.staticTexts["No standing grant found"].waitForExistence(timeout: 5))
        XCTAssertTrue(missing.staticTexts["Not registered — captures may be refused"].exists)
        XCTAssertTrue(missing.buttons["heimdal.record"].exists)
    }

    private func launchHeimdal(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "-ui-testing-auth-unlocked",
            "-ui-testing-uat-fixture",
            UUID().uuidString
        ] + arguments
        app.launch()
        let heimdalTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Heimdal"))
            .firstMatch
        XCTAssertTrue(heimdalTab.waitForExistence(timeout: 10))
        heimdalTab.tap()
        XCTAssertTrue(app.navigationBars["Heimdal"].waitForExistence(timeout: 5))
        return app
    }
}
