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
        // The fixture leads with an unrelated `place_optin` grant, so surfacing
        // the self-record grant proves the surface selects rather than takes
        // the first row.
        let granted = launchHeimdal(arguments: [])
        XCTAssertTrue(granted.staticTexts["Standing grant: fixture consent"].waitForExistence(timeout: 15))
        XCTAssertFalse(granted.staticTexts["Standing grant: fixture place opt-in"].exists)
        XCTAssertTrue(granted.staticTexts["Not registered — captures may be refused"].exists)
        XCTAssertTrue(granted.buttons["heimdal.registration.register"].exists)

        granted.terminate()

        let missing = launchHeimdal(arguments: ["-ui-testing-no-consent"])
        XCTAssertTrue(missing.staticTexts["No standing grant found"].waitForExistence(timeout: 15))
        XCTAssertTrue(missing.staticTexts["Not registered — captures may be refused"].exists)
        XCTAssertTrue(missing.buttons["heimdal.record"].exists)
    }

    /// A consent note that *has* grants, none of them an active self-record
    /// grant, must reach the same truthful empty state as a missing note.
    func testConsentSurfaceShowsEmptyStateWhenNoActiveSelfRecordGrant() throws {
        let app = launchHeimdal(arguments: ["-ui-testing-consent-no-active-grant"])

        // The empty-state Label surfaces as different element types across the
        // compact and regular layouts, so match the identifier on any element.
        let emptyState = app.descendants(matching: .any)
            .matching(identifier: "heimdal.consent.empty")
            .firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["No standing grant found"].exists)
        XCTAssertFalse(app.staticTexts["Standing grant: fixture place opt-in"].exists)
        XCTAssertFalse(app.staticTexts["Standing grant: fixture expired consent"].exists)
        XCTAssertFalse(app.staticTexts["Standing grant: fixture revoked consent"].exists)
        XCTAssertTrue(app.staticTexts["Not registered — captures may be refused"].exists)
        XCTAssertTrue(app.buttons["heimdal.record"].exists)

        // Leave no running instance behind: the next test relaunches with
        // different launch arguments, and an implicit takeover of a live app
        // is a needless source of flake.
        app.terminate()
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
        XCTAssertTrue(app.navigationBars["Heimdal"].waitForExistence(timeout: 15))
        return app
    }
}
