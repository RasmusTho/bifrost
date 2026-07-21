import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureSessionModelTests: XCTestCase {
    func testTransitionTableAndIllegalMoves() {
        let model = CaptureSessionModel()

        XCTAssertFalse(model.transition(to: .paused))
        XCTAssertTrue(model.transition(to: .recording))
        XCTAssertTrue(model.transition(to: .paused))
        XCTAssertTrue(model.transition(to: .recording))
        XCTAssertTrue(model.transition(to: .finalizing))
        XCTAssertFalse(model.transition(to: .recording))

        let itemID = UUID()
        XCTAssertTrue(model.stageCurrentItem(id: itemID))
        XCTAssertEqual(model.phase, .staged)
        XCTAssertEqual(model.stagedItems.first?.deliveryState, .deliveryPending)
        XCTAssertTrue(model.updateDeliveryState(for: itemID, to: .delivered))
        XCTAssertEqual(model.stagedItems.first?.deliveryState, .delivered)
        XCTAssertFalse(model.updateDeliveryState(for: UUID(), to: .failed))
        XCTAssertTrue(model.transition(to: .recording))
    }
}
