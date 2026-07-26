import XCTest
@testable import Yggdrasil

final class TestSeamGatingTests: XCTestCase {
    func testFixtureVaultSeamRequiresLaunchArgument() {
        let withoutTestMode = UITestLaunchConfiguration(arguments: ["-ui-testing-uat-fixture"])
        XCTAssertNil(withoutTestMode.fixtureKind)
        XCTAssertFalse(withoutTestMode.holdsAuthenticationGate)

        let fixtureMode = UITestLaunchConfiguration(
            arguments: ["-ui-testing", "-ui-testing-uat-fixture", "fixture-7"]
        )
        XCTAssertEqual(fixtureMode.fixtureKind, .uat)
        XCTAssertEqual(fixtureMode.fixtureIdentifier, "fixture-7")

        let lockedMode = UITestLaunchConfiguration(arguments: ["-ui-testing", "-ui-testing-auth-locked"])
        XCTAssertTrue(lockedMode.holdsAuthenticationGate)
    }
}
