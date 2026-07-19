import AVFoundation
import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureRecorderTests: XCTestCase {
    func testBackgroundTransitionKeepsSessionRecording() {
        let recorder = makeRecorder()
        XCTAssertTrue(recorder.configuration.audioBackgroundModeEnabled)
        recorder.start()
        XCTAssertEqual(recorder.sessionModel.phase, .recording)
    }

    func testInterruptionPausesAndResumes() async {
        let recorder = makeRecorder()
        recorder.start()
        await recorder.handleInterruption(type: .began, shouldResume: false)
        XCTAssertEqual(recorder.sessionModel.phase, .paused)
        await recorder.handleInterruption(type: .ended, shouldResume: true)
        XCTAssertEqual(recorder.sessionModel.phase, .recording)
    }

    func testNonResumableInterruptionThenStopClearsManualResumeState() async {
        let recorder = makeRecorder()
        recorder.start()
        await recorder.handleInterruption(type: .began, shouldResume: false)
        await recorder.handleInterruption(type: .ended, shouldResume: false)
        XCTAssertEqual(recorder.sessionModel.phase, .paused)
        XCTAssertTrue(recorder.needsManualResume)

        await recorder.stop()

        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertFalse(recorder.needsManualResume)
        await recorder.handleInterruption(type: .ended, shouldResume: false)
        XCTAssertFalse(recorder.needsManualResume)
    }

    func testAbandonedSessionFinalizesSegment() async {
        let recorder = makeRecorder()
        recorder.start()
        await recorder.handleInterruption(type: .began, shouldResume: false)
        await recorder.abandon()
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    func testFinalizedSegmentStagedWithUniqueName() async {
        let recorder = makeRecorder()
        recorder.start()
        await recorder.stop()
        recorder.start()
        await recorder.stop()
        let items = recorder.sessionModel.stagedItems
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].url.pathExtension, "m4a")
        XCTAssertEqual(items[1].url.pathExtension, "m4a")
        XCTAssertTrue(items.allSatisfy { $0.url.lastPathComponent.hasPrefix("heimdal-test-device-") })
        XCTAssertNotEqual(items[0].url.lastPathComponent, items[1].url.lastPathComponent)
    }

    func testStagedImpliesFullyWrittenFile() async throws {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let stopTask = Task { await recorder.stop() }
        for _ in 0..<20 where !writer.isWaitingToFinish {
            await Task.yield()
        }
        XCTAssertTrue(writer.isWaitingToFinish)
        XCTAssertEqual(recorder.sessionModel.phase, .finalizing)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)
        writer.completeStop()
        await stopTask.value
        let item = try XCTUnwrap(recorder.sessionModel.stagedItems.first)
        XCTAssertGreaterThan(try item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }

    func testRouteChangeFinalizesThroughCompletionBoundary() async {
        let recorder = makeRecorder(observeInterruptions: true)
        recorder.start()
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        await waitUntilStaged(recorder)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    func testSessionFailureFinalizesThroughCompletionBoundary() async {
        let recorder = makeRecorder(observeInterruptions: true)
        recorder.start()
        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereLostNotification,
            object: AVAudioSession.sharedInstance()
        )
        await waitUntilStaged(recorder)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    private func makeRecorder(
        writer: FakeCaptureWriter? = nil,
        observeInterruptions: Bool = false
    ) -> CaptureRecorder {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return CaptureRecorder(
            writer: writer ?? FakeCaptureWriter(),
            stagingDirectory: directory,
            deviceShortID: "test-device",
            observeInterruptions: observeInterruptions
        )
    }

    private func waitUntilStaged(_ recorder: CaptureRecorder) async {
        for _ in 0..<20 where recorder.sessionModel.phase != .staged {
            await Task.yield()
        }
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
    }
}

@MainActor
private final class FakeCaptureWriter: CaptureFileWriting {
    private var url: URL?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private let autoComplete: Bool
    private(set) var isWaitingToFinish = false

    init(autoComplete: Bool = true) {
        self.autoComplete = autoComplete
    }

    func start(url: URL) throws {
        self.url = url
    }

    func pause() {}
    func resume() throws {}

    func stop() async throws -> TimeInterval {
        guard let url else { throw CaptureRecorder.Error.incompleteFile }
        if !autoComplete {
            isWaitingToFinish = true
            await withCheckedContinuation { stopContinuation = $0 }
        }
        try Data("captured audio".utf8).write(to: url)
        return 2
    }

    func completeStop() {
        isWaitingToFinish = false
        stopContinuation?.resume()
        stopContinuation = nil
    }
}
