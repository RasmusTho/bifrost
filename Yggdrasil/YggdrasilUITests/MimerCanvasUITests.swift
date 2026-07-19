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

    private func launchMimerShell() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing-auth-unlocked", "-ui-testing-mimer-shell"]
        app.launch()
        return app
    }
}
