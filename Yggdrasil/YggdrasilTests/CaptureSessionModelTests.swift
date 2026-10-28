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

    /// A denied microphone is named as such, routes to Heimdal's Settings page
    /// (the one recovery iOS permits), and blocks starting a capture; the
    /// recorder neither re-prompts nor begins writing. Restricted and
    /// unavailable are distinct states with their own truthful recovery, and
    /// recording, staged, and failed each read differently.
    func testDeniedPermissionOffersSettingsRecovery() async {
        let model = CaptureSessionModel()
        XCTAssertEqual(model.captureStatus.kind, .ready)
        XCTAssertTrue(model.captureStatus.canStartRecording)

        model.updateMicrophone(.denied)
        let denied = model.captureStatus
        XCTAssertEqual(denied.kind, .permissionDenied)
        XCTAssertEqual(denied.recovery, .openSettings)
        XCTAssertEqual(denied.recovery?.title, "Open Settings")
        XCTAssertEqual(denied.tone, .failure)
        XCTAssertFalse(denied.canStartRecording)

        model.updateMicrophone(.restricted)
        XCTAssertEqual(model.captureStatus.kind, .permissionRestricted)
        XCTAssertNil(model.captureStatus.recovery, "Heimdal's Settings page cannot lift a Screen Time restriction.")
        XCTAssertFalse(model.captureStatus.canStartRecording)

        model.updateMicrophone(.unavailable)
        XCTAssertEqual(model.captureStatus.kind, .inputUnavailable)
        XCTAssertEqual(model.captureStatus.recovery, .checkAgain)
        XCTAssertTrue(model.captureStatus.canStartRecording, "A missing input still allows an honest attempt.")

        model.updateMicrophone(.granted)
        XCTAssertTrue(model.transition(to: .recording))
        let recording = model.captureStatus
        XCTAssertEqual(recording.kind, .recording)
        XCTAssertFalse(recording.canStartRecording)

        // A live recording is not relabelled by a later OS read.
        model.updateMicrophone(.denied)
        XCTAssertEqual(model.captureStatus.kind, .recording)
        model.updateMicrophone(.granted)

        XCTAssertTrue(model.transition(to: .finalizing))
        XCTAssertTrue(model.stageCurrentItem())
        let staged = model.captureStatus
        XCTAssertEqual(staged.kind, .staged)
        XCTAssertEqual(staged.tone, .pending)
        XCTAssertTrue(staged.message.contains("not confirmed"), "Staged must not claim delivery: \(staged.message)")

        XCTAssertTrue(model.transition(to: .recording))
        XCTAssertTrue(model.transition(to: .finalizing))
        XCTAssertTrue(model.failCurrentItem())
        let failed = model.captureStatus
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertEqual(failed.recovery, .recordAgain)

        let shown = [denied, recording, staged, failed]
        XCTAssertEqual(Set(shown.map(\.title)).count, shown.count, "Each state needs its own visible title.")
        XCTAssertEqual(Set(shown.map(\.systemImage)).count, shown.count, "Each state needs its own glyph.")

        await assertDeniedRecorderDoesNotStart()
    }

    private func assertDeniedRecorderDoesNotStart() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = CaptureRecorder(
            stagingDirectory: directory,
            deviceID: "denied-device",
            observeInterruptions: false,
            microphoneProbe: MicrophoneAvailabilityProbe { .denied }
        )
        XCTAssertEqual(recorder.sessionModel.microphone, .undetermined, "Init leaves the audio session alone.")
        await recorder.requestMicrophonePermissionAndStart()
        XCTAssertEqual(recorder.sessionModel.microphone, .denied, "Pressing Record re-reads the OS state.")
        XCTAssertEqual(recorder.sessionModel.phase, .idle)
        XCTAssertNil(recorder.activeCaptureGeneration)
        XCTAssertEqual(recorder.sessionModel.captureStatus.recovery, .openSettings)
    }
}
