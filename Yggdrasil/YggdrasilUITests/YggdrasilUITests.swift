import XCTest

final class YggdrasilUITests: XCTestCase {
    func testAppLaunchesToAuthOrVaultPicker() throws {
        let app = XCUIApplication()
        app.launch()
        // No enrolled biometry/passcode in CI simulators fails the auth
        // policy open, so RootView shows the vault picker; either that or
        // the auth gate's title should be on screen immediately at launch.
        let title = app.staticTexts["Yggdrasil"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
    }
}
