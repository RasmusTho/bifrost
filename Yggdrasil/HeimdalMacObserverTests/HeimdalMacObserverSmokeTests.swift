import XCTest
@testable import HeimdalMacObserver

final class HeimdalMacObserverSmokeTests: XCTestCase {
    func testFoundationRuntimeSeamLaunchesWithoutScreenCapture() {
        let runtime = HeimdalMacObserverRuntime()

        XCTAssertEqual(HeimdalMacObserverRuntime.identifier, "HeimdalMacObserver")
        XCTAssertFalse(runtime.screenCaptureEnabled)
    }
}
