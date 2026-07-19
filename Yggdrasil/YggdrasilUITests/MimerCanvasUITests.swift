import XCTest
import UIKit

final class MimerCanvasUITests: XCTestCase {
    func testIPadShowsThreeColumnCanvasWithAllLenses() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad-only canvas verification")
        let app = launchMimerShell()

        XCTAssertTrue(app.otherElements["mimer.canvas.splitView"].waitForExistence(timeout: 10))
        for lens in ["today", "interests", "entities", "consent", "vault", "settings"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["mimer.canvas.lens.\(lens)"].exists,
                "Expected the \(lens) lens in the iPad canvas sidebar."
            )
        }
        XCTAssertTrue(app.otherElements["mimer.canvas.content"].exists)
        XCTAssertTrue(app.otherElements["mimer.canvas.detail"].exists)
    }

    func testIPhoneKeepsTabBar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-only tab verification")
        let app = launchMimerShell()

        XCTAssertTrue(app.otherElements["mimer.compact.tabView"].waitForExistence(timeout: 10))
        for tab in ["Today", "Interests", "Entities", "Consent", "Vault", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "Expected the shipped \(tab) tab.")
        }
        XCTAssertFalse(app.otherElements["mimer.canvas.splitView"].exists)
    }

    private func launchMimerShell() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing-auth-unlocked", "-ui-testing-mimer-shell"]
        app.launch()
        return app
    }
}
