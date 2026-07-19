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
        await recorder.stop()
        XCTAssertTrue(writer.isWaitingToFinish)
        XCTAssertEqual(recorder.sessionModel.phase, .finalizing)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)

        writer.completeStop()

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

    func testExceptionalSessionLossTerminatesWithoutDelegateCallback() async {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()

        await recorder.handleRouteChangeOrSessionFailure()

        XCTAssertEqual(writer.normalStopCount, 0)
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    func testInterruptedStopTerminatesWithoutDelegateCallback() async {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        await recorder.handleInterruption(type: .began, shouldResume: false)

        await recorder.stop()

        XCTAssertEqual(writer.normalStopCount, 0)
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    func testSessionLossEscalatesInFlightDelegateFinalization() async {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        await recorder.stop()
        XCTAssertEqual(recorder.sessionModel.phase, .finalizing)

        await recorder.handleRouteChangeOrSessionFailure()

        XCTAssertEqual(writer.normalStopCount, 1)
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
    }

    func testPreStopEncodeErrorWinsCallbackRaceExactlyOnce() async throws {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let generation = try XCTUnwrap(recorder.activeCaptureGeneration)

        writer.failEncoding(generation: generation, description: "encoder unavailable")
        writer.completeSuccessfully(generation: generation)
        await recorder.stop()

        XCTAssertEqual(recorder.sessionModel.phase, .failed)
        XCTAssertTrue(recorder.lastError?.contains("encoder unavailable") == true)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)
        XCTAssertEqual(writer.normalStopCount, 0)
    }

    func testStalePriorGenerationNotificationsCannotMutateNextCapture() async throws {
        let writer = FakeCaptureWriter()
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let firstGeneration = try XCTUnwrap(recorder.activeCaptureGeneration)
        await recorder.stop()
        recorder.start()
        let secondGeneration = try XCTUnwrap(recorder.activeCaptureGeneration)
        XCTAssertNotEqual(firstGeneration, secondGeneration)

        await recorder.handleInterruption(
            type: .began,
            shouldResume: false,
            captureGeneration: firstGeneration
        )
        recorder.handleRouteChangeOrSessionFailure(captureGeneration: firstGeneration)
        writer.completeSuccessfully(generation: firstGeneration)

        XCTAssertEqual(recorder.sessionModel.phase, .recording)
        XCTAssertEqual(recorder.activeCaptureGeneration, secondGeneration)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)
    }

    func testMediaServicesResetDisposesWriterBeforeNextCapture() async throws {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let firstGeneration = try XCTUnwrap(recorder.activeCaptureGeneration)

        await recorder.handleRouteChangeOrSessionFailure()
        recorder.start()
        let secondGeneration = try XCTUnwrap(recorder.activeCaptureGeneration)

        XCTAssertEqual(writer.startedGenerations, [firstGeneration, secondGeneration])
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .recording)
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
    private var urls: [UInt64: URL] = [:]
    private var terminalHandlers: [
        UInt64: @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ] = [:]
    private let autoComplete: Bool
    private(set) var isWaitingToFinish = false
    private(set) var normalStopCount = 0
    private(set) var forcedStopCount = 0
    private(set) var startedGenerations: [UInt64] = []

    init(autoComplete: Bool = true) {
        self.autoComplete = autoComplete
    }

    func start(
        url: URL,
        generation: UInt64,
        onTerminal: @escaping @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ) throws {
        urls[generation] = url
        terminalHandlers[generation] = onTerminal
        startedGenerations.append(generation)
    }

    func pause() {}
    func resume() throws {}

    func stop(generation: UInt64) throws {
        normalStopCount += 1
        guard urls[generation] != nil else { throw CaptureFileWriterFailure.incompleteFile }
        if autoComplete {
            completeSuccessfully(generation: generation)
        } else {
            isWaitingToFinish = true
        }
    }

    func forceTerminate(generation: UInt64) throws {
        forcedStopCount += 1
        guard urls[generation] != nil else { throw CaptureFileWriterFailure.incompleteFile }
        completeSuccessfully(generation: generation)
    }

    func completeStop() {
        guard let generation = startedGenerations.last else {
            XCTFail("No capture is available to complete")
            return
        }
        completeSuccessfully(generation: generation)
    }

    func completeSuccessfully(generation: UInt64) {
        guard let url = urls[generation], let handler = terminalHandlers[generation] else { return }
        isWaitingToFinish = false
        do {
            try Data("captured audio".utf8).write(to: url)
            handler(CaptureFileWriterTerminalEvent(generation: generation, result: .success(2)))
        } catch {
            handler(CaptureFileWriterTerminalEvent(
                generation: generation,
                result: .failure(.incompleteFile)
            ))
        }
    }

    func failEncoding(generation: UInt64, description: String) {
        terminalHandlers[generation]?(CaptureFileWriterTerminalEvent(
            generation: generation,
            result: .failure(.encodingFailed(description))
        ))
    }
}
