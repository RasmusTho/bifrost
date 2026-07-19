import XCTest

final class HeimdalShellUITests: XCTestCase {
    func testHeimdalAreaReachable() throws {
        let app = XCUIApplication()
        app.launch()

        let heimdalTab = app.tabBars.buttons["Heimdal"]
        XCTAssertTrue(heimdalTab.waitForExistence(timeout: 10))
        heimdalTab.tap()
        XCTAssertTrue(app.navigationBars["Heimdal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["heimdal.chooseCaptureFolder"].exists)
        XCTAssertTrue(app.buttons["heimdal.record.disabled"].exists)
    }
}
