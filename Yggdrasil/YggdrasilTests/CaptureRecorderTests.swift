import AVFoundation
import XCTest
@testable import Yggdrasil

enum CaptureTestAudio {
    static let validM4A: Data = {
        let base64 = """
        AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAABeW1kYXTeAgBMYXZjNjIuMTEuMTAwAAJ8ZRfGgxVVmevz
        +/tLuSSJEiEhEHnzwa7/pBrv+kGu/zgov84KL0wUAQCMTENkxVVTFVVMVVUxVVTFVVMVVUxVVTFVVMVSJiqqmJFUxVVTEhBy
        7KpikqmLsqmKSo5SVTXSVTXSVHukqPdIg5SA90lR7pKj3Sb6bpN/hdJvpuk3+F0m+m6Tee6SPC6SMQxGfEMRnxDEZ8QxG2IY
        jbEMRtiGIz4hiM+IYjPiGI+AATQyi+ZVVWOeft9+NS5CREIggDuh/MnQfMnQf4HuPge5fBs5fAzwv5gb3HwbPD8GzlkN7w5G
        88ORvPDkbzw5G85ZDZ4cjeeHI3nhyN54cjeeHI3nhyN54cjeeHI3nhyN54X23YcjeeHI3nhyN54X288ORvPDkbzw5G88ORvP
        C+27C+27C+27C+27C+3nhyN54cjeeF9t2F9t2F9t2F9t2F9t2F9t2F9t2F9t2F9t2F9t2HgAAAMCbW9vdgAAAGxtdmhkAAAA
        AAAAAAAAAAAAAAAD6AAAAFAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAi10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAFAAAAAAAAAA
        AAAAAAEBAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAA
        AAAAAAEAAABQAAAEAAABAAAAAAGlbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAfQAAABoBVxAAAAAAALWhkbHIAAAAAAAAA
        AHNvdW4AAAAAAAAAAAAAAABTb3VuZEhhbmRsZXIAAAABUG1pbmYAAAAQc21oZAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAA
        AAAAAAABAAAADHVybCAAAAABAAABFHN0YmwAAABqc3RzZAAAAAAAAAABAAAAWm1wNGEAAAAAAAAAAQAAAAAAAAAAAAEAEAAA
        AAAfQAAAAAAANmVzZHMAAAAAA4CAgCUAAQAEgICAF0AVAAAAAAA3cAAAN3AFgICABRWIVuUABoCAgAECAAAAIHN0dHMAAAAA
        AAAAAgAAAAEAAAQAAAAAAQAAAoAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAIAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAIAAAC+
        AAAAswAAABRzdGNvAAAAAAAAAAEAAAAsAAAAGnNncGQBAAAAcm9sbAAAAAIAAAAB//8AAAAcc2JncAAAAAByb2xsAAAAAQAA
        AAIAAAABAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxzdAAAACSp
        dG9vAAAAHGRhdGEAAAABAAAAAExhdmY2Mi4zLjEwMA==
        """.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: base64) else {
            fatalError("The production-format M4A fixture must decode")
        }
        return data
    }()

    static let truncatedM4A = Data(validM4A.prefix(validM4A.count / 2))
}

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

    func testAutomaticResumeFailureExposesManualRetry() async throws {
        let writer = FakeCaptureWriter(resumeFailuresRemaining: 1)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let generation = try XCTUnwrap(recorder.activeCaptureGeneration)
        await recorder.handleInterruption(type: .began, shouldResume: false)
        await recorder.handleInterruption(type: .ended, shouldResume: true)
        XCTAssertEqual(recorder.sessionModel.phase, .paused)
        XCTAssertTrue(recorder.needsManualResume)
        XCTAssertEqual(recorder.activeCaptureGeneration, generation)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)
        recorder.resume()
        XCTAssertEqual(recorder.sessionModel.phase, .recording)
        XCTAssertFalse(recorder.needsManualResume)
        XCTAssertEqual(recorder.activeCaptureGeneration, generation)
        XCTAssertEqual(writer.resumeAttempts, 2)
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

    func testRestartRecoversFinalizedDecodableM4AIntoPendingItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent("heimdal-test-device-20260720-120000-orphan.m4a")
        try CaptureTestAudio.validM4A.write(to: orphan)

        let relaunchedRecorder = CaptureRecorder(
            writer: FakeCaptureWriter(),
            stagingDirectory: directory,
            deviceShortID: "test-device",
            observeInterruptions: false
        )

        let recovered = try XCTUnwrap(relaunchedRecorder.sessionModel.stagedItems.first)
        XCTAssertEqual(relaunchedRecorder.sessionModel.phase, .staged)
        XCTAssertEqual(recovered.url, orphan)
        XCTAssertEqual(recovered.deliveryState, .staged)
        XCTAssertTrue(recovered.wasRecoveredAfterRestart)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(relaunchedRecorder.sessionModel.recoveryFailures.isEmpty)
    }

    func testRestartPreservesTruncatedM4AAsExplicitRecoveryFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let truncatedM4A = directory.appendingPathComponent("heimdal-interrupted.m4a")
        let emptyM4A = directory.appendingPathComponent("heimdal-empty.m4a")
        let truncatedBytes = CaptureTestAudio.truncatedM4A
        try truncatedBytes.write(to: truncatedM4A)
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyM4A.path, contents: nil))

        let relaunchedRecorder = CaptureRecorder(
            writer: FakeCaptureWriter(),
            stagingDirectory: directory,
            deviceShortID: "test-device",
            observeInterruptions: false
        )

        XCTAssertTrue(relaunchedRecorder.sessionModel.stagedItems.isEmpty)
        let failures = relaunchedRecorder.sessionModel.recoveryFailures
        XCTAssertEqual(Set(failures.map(\.url)), Set([truncatedM4A, emptyM4A]))
        XCTAssertTrue(failures.allSatisfy { $0.reason == .invalidOrUnverifiableMedia })
        XCTAssertTrue(relaunchedRecorder.lastError?.contains("could not be verified") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: truncatedM4A.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyM4A.path))
        XCTAssertEqual(try Data(contentsOf: truncatedM4A), truncatedBytes)
    }

    func testTerminalSuccessPreservesUndecodableBytesWithoutStaging() async throws {
        let writer = FakeCaptureWriter(outputData: CaptureTestAudio.truncatedM4A)
        let recorder = makeRecorder(writer: writer)

        recorder.start()
        await recorder.stop()

        XCTAssertEqual(recorder.sessionModel.phase, .failed)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)
        XCTAssertTrue(recorder.lastError?.contains("complete, decodable audio") == true)
        let outputURL = try XCTUnwrap(writer.lastOutputURL)
        XCTAssertEqual(try Data(contentsOf: outputURL), CaptureTestAudio.truncatedM4A)
        let recoveryFailure = try XCTUnwrap(recorder.sessionModel.recoveryFailures.first)
        XCTAssertEqual(recoveryFailure.url, outputURL)
        XCTAssertEqual(recoveryFailure.reason, .invalidOrUnverifiableMedia)

        recorder.start()

        XCTAssertEqual(recorder.sessionModel.phase, .recording)
        XCTAssertNil(recorder.lastError)
        XCTAssertEqual(recorder.sessionModel.recoveryFailures.first?.url, outputURL)
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
}

extension CaptureRecorderTests {
    func testInterruptionDuringDelegateFinalizationForcesTerminalOnce() async throws {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let generation = try XCTUnwrap(recorder.activeCaptureGeneration)
        await recorder.stop()
        XCTAssertEqual(recorder.sessionModel.phase, .finalizing)

        await recorder.handleInterruption(type: .began, shouldResume: false)

        XCTAssertEqual(writer.normalStopCount, 1)
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertEqual(recorder.sessionModel.stagedItems.count, 1)

        writer.failEncoding(generation: generation, description: "late encoder failure")
        await recorder.handleInterruption(
            type: .began,
            shouldResume: false,
            captureGeneration: generation
        )
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .staged)
        XCTAssertNil(recorder.lastError)
    }

    func testQueuedEncodeFailureWinsInterruptionForcedCompletion() async throws {
        let writer = FakeCaptureWriter(autoComplete: false)
        let recorder = makeRecorder(writer: writer)
        recorder.start()
        let generation = try XCTUnwrap(recorder.activeCaptureGeneration)
        await recorder.stop()
        writer.queueEncodingFailure(
            generation: generation,
            description: "queued encoder failure"
        )

        await recorder.handleInterruption(type: .began, shouldResume: false)

        XCTAssertEqual(writer.normalStopCount, 1)
        XCTAssertEqual(writer.forcedStopCount, 1)
        XCTAssertEqual(recorder.sessionModel.phase, .failed)
        XCTAssertTrue(recorder.lastError?.contains("queued encoder failure") == true)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)

        writer.completeSuccessfully(generation: generation)
        XCTAssertEqual(recorder.sessionModel.phase, .failed)
        XCTAssertTrue(recorder.sessionModel.stagedItems.isEmpty)
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
    private var queuedTerminalResults: [
        UInt64: [Result<TimeInterval, CaptureFileWriterFailure>]
    ] = [:]
    private var terminalHandlers: [
        UInt64: @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ] = [:]
    private let autoComplete: Bool
    private let outputData: Data
    private var resumeFailuresRemaining: Int
    private(set) var isWaitingToFinish = false
    private(set) var normalStopCount = 0
    private(set) var forcedStopCount = 0
    private(set) var startedGenerations: [UInt64] = []
    private(set) var resumeAttempts = 0
    var lastOutputURL: URL? {
        guard let generation = startedGenerations.last else { return nil }
        return urls[generation]
    }

    init(
        autoComplete: Bool = true,
        outputData: Data = CaptureTestAudio.validM4A,
        resumeFailuresRemaining: Int = 0
    ) {
        self.autoComplete = autoComplete
        self.outputData = outputData
        self.resumeFailuresRemaining = resumeFailuresRemaining
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
    func resume() throws {
        resumeAttempts += 1
        if resumeFailuresRemaining > 0 {
            resumeFailuresRemaining -= 1
            throw CaptureFileWriterFailure.encodingFailed("resume failed")
        }
    }

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
        if var queuedResults = queuedTerminalResults[generation], !queuedResults.isEmpty {
            let result = queuedResults.removeFirst()
            queuedTerminalResults[generation] = queuedResults
            deliver(result: result, generation: generation)
        } else {
            completeSuccessfully(generation: generation)
        }
    }

    func completeStop() {
        guard let generation = startedGenerations.last else {
            XCTFail("No capture is available to complete")
            return
        }
        completeSuccessfully(generation: generation)
    }

    func completeSuccessfully(generation: UInt64) {
        deliver(result: .success(2), generation: generation)
    }

    func queueEncodingFailure(generation: UInt64, description: String) {
        queuedTerminalResults[generation, default: []].append(
            .failure(.encodingFailed(description))
        )
    }

    func failEncoding(generation: UInt64, description: String) {
        terminalHandlers[generation]?(CaptureFileWriterTerminalEvent(
            generation: generation,
            result: .failure(.encodingFailed(description))
        ))
    }

    private func deliver(
        result: Result<TimeInterval, CaptureFileWriterFailure>,
        generation: UInt64
    ) {
        guard let url = urls[generation], let handler = terminalHandlers[generation] else { return }
        isWaitingToFinish = false
        do {
            if case .success = result {
                try outputData.write(to: url)
            }
            handler(CaptureFileWriterTerminalEvent(generation: generation, result: result))
        } catch {
            handler(CaptureFileWriterTerminalEvent(
                generation: generation,
                result: .failure(.incompleteFile)
            ))
        }
    }
}
