import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureSessionModelTests: XCTestCase {
    /// Enforces ADR-0049 §2's declared bend against the real, on-disk
    /// production `VaultFileStore` seam, not a mock: `DeviceHealthPanelModel`
    /// is driven through the same `CaptureSessionModel` production flow the
    /// app ships (transitions, staging, delivery-state updates) plus every
    /// telemetry setter it offers, while a real vault directory sits beside
    /// it. If the panel ever gained a persistence side effect, this directory
    /// would gain a file; a mock spy could be fooled by an unused parameter,
    /// but an empty directory on disk cannot.
    func testLivePanelHasNoPersistenceSideEffects() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureSessionModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let session = CaptureSessionModel()
        let panel = DeviceHealthPanelModel(captureSession: session)

        session.transition(to: .recording)
        panel.updateBattery(DeviceBatteryStatus(level: 0.42, state: .unplugged))
        session.transition(to: .finalizing)
        let itemID = UUID()
        session.stageCurrentItem(id: itemID, capturedAt: Date())
        panel.updateStorageHeadroom(bytes: 1_000_000)
        panel.updateMicPermission(.granted)
        session.updateDeliveryState(for: itemID, to: .delivering(startedAt: Date()))
        panel.updateBattery(DeviceBatteryStatus(level: 0.41, state: .unplugged))
        session.transition(to: .recording)

        _ = panel.recordingPhase
        _ = panel.queueDepth
        _ = panel.oldestPendingAge

        let entries = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertTrue(entries.isEmpty, "The live panel wrote to the vault: \(entries)")
    }
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
