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

    func testInterruptionPausesAndResumes() {
        let recorder = makeRecorder()
        recorder.start()
        recorder.handleInterruption(type: .began, shouldResume: false)
        XCTAssertEqual(recorder.sessionModel.phase, .paused)
        recorder.handleInterruption(type: .ended, shouldResume: true)
        XCTAssertEqual(recorder.sessionModel.phase, .recording)
    }

    func testAbandonedSessionFinalizesSegment() {
        let recorder = makeRecorder()
        recorder.start()
        recorder.handleInterruption(type: .began, shouldResume: false)
        recorder.abandon()
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    func testFinalizedSegmentStagedWithUniqueName() {
        let recorder = makeRecorder()
        recorder.start()
        recorder.stop()
        let item = recorder.sessionModel.stagedItems.first
        XCTAssertEqual(item?.url.pathExtension, "m4a")
        XCTAssertTrue(item?.url.lastPathComponent.hasPrefix("heimdal-test-device-") == true)
    }

    func testStagedImpliesFullyWrittenFile() throws {
        let recorder = makeRecorder()
        recorder.start()
        recorder.stop()
        let item = try XCTUnwrap(recorder.sessionModel.stagedItems.first)
        XCTAssertGreaterThan(try item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }

    private func makeRecorder() -> CaptureRecorder {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return CaptureRecorder(
            writer: FakeCaptureWriter(),
            stagingDirectory: directory,
            deviceShortID: "test-device",
            observeInterruptions: false
        )
    }
}

private final class FakeCaptureWriter: CaptureFileWriting {
    private var url: URL?
    var duration: TimeInterval { 2 }

    func start(url: URL) throws {
        self.url = url
        try Data("captured audio".utf8).write(to: url)
    }

    func pause() {}
    func resume() throws {}
    func stop() throws { XCTAssertNotNil(url) }
}
