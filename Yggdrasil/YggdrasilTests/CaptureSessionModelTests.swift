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
        XCTAssertEqual(model.stagedItems.first?.deliveryState, .staged)
        let placedAt = Date()
        XCTAssertTrue(model.updateDeliveryState(for: itemID, to: .deliveredAwaitingSync(placedAt: placedAt)))
        XCTAssertEqual(model.stagedItems.first?.deliveryState, .deliveredAwaitingSync(placedAt: placedAt))
        XCTAssertFalse(model.updateDeliveryState(
            for: UUID(),
            to: .failed(message: "failure", at: Date())
        ))
        XCTAssertTrue(model.transition(to: .recording))
    }
}
