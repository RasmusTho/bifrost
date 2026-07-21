import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureDeliveryTests: XCTestCase {
    func testTempNameThenRenameNeverExposesPartial() throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-test.m4a")
        try Data("complete recording".utf8).write(to: source)
        let coordinator = RecordingDeliveryCoordinator()
        let placer = CaptureDeliveryFilePlacer(
            coordinator: coordinator,
            bytesCopier: MidCopyFailingBytesCopier()
        )

        XCTAssertThrowsError(try placer.place(stagedURL: source, in: captureFolder))

        let finalURL = captureFolder.appendingPathComponent(source.lastPathComponent)
        let tempURL = captureFolder.appendingPathComponent("\(source.lastPathComponent).uploading")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: tempURL), Data("partial".utf8))
        XCTAssertEqual(coordinator.writeCount, 1)
    }

    func testSameLengthCorruptionNeverBecomesAdmissibleAndPreservesStaging() throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-test.m4a")
        let sourceBytes = Data("complete recording".utf8)
        try sourceBytes.write(to: source)
        let placer = CaptureDeliveryFilePlacer(
            coordinator: RecordingDeliveryCoordinator(),
            bytesCopier: SameLengthCorruptingBytesCopier()
        )

        XCTAssertThrowsError(try placer.place(stagedURL: source, in: captureFolder)) { error in
            guard case CaptureDeliveryError.incompletePlacement = error else {
                return XCTFail("Expected incomplete-placement custody failure, got \(error)")
            }
        }

        let finalURL = captureFolder.appendingPathComponent(source.lastPathComponent)
        let tempURL = captureFolder.appendingPathComponent("\(source.lastPathComponent).uploading")
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: tempURL).count, sourceBytes.count)
        XCTAssertNotEqual(try Data(contentsOf: tempURL), sourceBytes)
    }

    func testLocalDeleteOnlyAfterConfirmedPlacement() async throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-test.m4a")
        let bytes = Data("complete recording".utf8)
        try bytes.write(to: source)
        let model = makeStagedModel(url: source)
        let itemID = try XCTUnwrap(model.stagedItems.first?.id)
        let failingQueue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: AlwaysFailingFilePlacer()
        )

        await failingQueue.deliver(itemID: itemID, to: captureFolder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        guard case .failed = try XCTUnwrap(model.stagedItems.first?.deliveryState) else {
            return XCTFail("A failed placement must remain visibly retryable")
        }

        let succeedingQueue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: RecordingDeliveryCoordinator())
        )
        await succeedingQueue.deliver(itemID: itemID, to: captureFolder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try Data(contentsOf: captureFolder.appendingPathComponent(source.lastPathComponent)),
            bytes
        )
        guard case .deliveredAwaitingSync = try XCTUnwrap(model.stagedItems.first?.deliveryState) else {
            return XCTFail("Confirmed placement must become delivered-awaiting-sync")
        }
    }

    func testQueueRebuiltFromStagingDirectory() throws {
        let stagingDirectory = try makeDirectory()
        let stagedURL = stagingDirectory.appendingPathComponent("heimdal-staged.m4a")
        let failedURL = stagingDirectory.appendingPathComponent("heimdal-failed.m4a")
        try Data("staged".utf8).write(to: stagedURL)
        try Data("failed".utf8).write(to: failedURL)

        let beforeRelaunch = CaptureSessionModel()
        beforeRelaunch.recoverStagedItem(url: failedURL, duration: 2, capturedAt: Date())
        let failedID = try XCTUnwrap(beforeRelaunch.stagedItems.first?.id)
        XCTAssertTrue(beforeRelaunch.updateDeliveryState(
            for: failedID,
            to: .failed(message: "Provider unavailable", at: Date())
        ))

        let relaunchedModel = CaptureSessionModel()
        _ = CaptureRecorder(
            sessionModel: relaunchedModel,
            writer: InertCaptureWriter(),
            stagingDirectory: stagingDirectory,
            deviceShortID: "test-device",
            observeInterruptions: false,
            mediaValidator: AlwaysValidCaptureMediaValidator()
        )

        XCTAssertEqual(Set(relaunchedModel.stagedItems.map(\.url)), Set([stagedURL, failedURL]))
        XCTAssertTrue(relaunchedModel.stagedItems.allSatisfy { item in
            item.wasRecoveredAfterRestart && item.deliveryState == .staged
        })
        XCTAssertTrue(relaunchedModel.recoveryFailures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
    }

    func testDeliveryUsesCoordinatedWrite() async throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-test.m4a")
        try Data("complete recording".utf8).write(to: source)
        let model = makeStagedModel(url: source)
        let itemID = try XCTUnwrap(model.stagedItems.first?.id)
        let coordinator = RecordingDeliveryCoordinator()
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: coordinator)
        )

        await queue.deliver(itemID: itemID, to: captureFolder)

        XCTAssertEqual(coordinator.writeCount, 1)
        XCTAssertEqual(coordinator.lastFolderURL, captureFolder)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: captureFolder.appendingPathComponent(source.lastPathComponent).path
        ))
    }

    func testRetryAfterRenameBeforeLocalDeleteConfirmsExistingIdenticalPlacement() async throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-test.m4a")
        let finalURL = captureFolder.appendingPathComponent(source.lastPathComponent)
        let bytes = Data("complete recording".utf8)
        try bytes.write(to: source)
        try bytes.write(to: finalURL)
        let model = makeStagedModel(url: source)
        let itemID = try XCTUnwrap(model.stagedItems.first?.id)
        let copier = RecordingBytesCopier()
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(
                coordinator: RecordingDeliveryCoordinator(),
                bytesCopier: copier
            )
        )

        await queue.deliver(itemID: itemID, to: captureFolder)

        XCTAssertEqual(copier.copyCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), bytes)
    }

    func testRecoveryDeliversAudioWithoutSidecarAndPreservesSidecarPlacedBeforeRestart() async throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-test.m4a")
        let audioURL = captureFolder.appendingPathComponent(source.lastPathComponent)
        let sidecarURL = captureFolder.appendingPathComponent(
            "\(source.lastPathComponent).capture.json"
        )
        let audio = Data("complete recording".utf8)
        let alreadyPlacedSidecar = Data("{\"sidecar_version\":1}".utf8)
        try audio.write(to: source)
        try audio.write(to: audioURL)
        try alreadyPlacedSidecar.write(to: sidecarURL)

        let model = CaptureSessionModel()
        _ = CaptureRecorder(
            sessionModel: model,
            writer: InertCaptureWriter(),
            stagingDirectory: stagingDirectory,
            deviceID: "registered-device-id",
            observeInterruptions: false,
            mediaValidator: AlwaysValidCaptureMediaValidator()
        )
        let recovered = try XCTUnwrap(model.stagedItems.first)
        XCTAssertTrue(recovered.wasRecoveredAfterRestart)
        XCTAssertNil(recovered.captureMetadata)

        let sidecarWriter = RejectingSidecarWriter()
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: RecordingDeliveryCoordinator()),
            sidecarWriter: sidecarWriter
        )

        await queue.deliver(itemID: recovered.id, to: captureFolder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), alreadyPlacedSidecar)
        XCTAssertEqual(sidecarWriter.writeCount, 0)
        guard case .deliveredAwaitingSync = try XCTUnwrap(model.stagedItems.first?.deliveryState) else {
            return XCTFail("Recovered audio should complete delivery without metadata fabrication")
        }
    }

}

extension CaptureDeliveryTests {
    func testWatchRelayedFileEntersStagingQueue() async throws {
        let incomingDirectory = try makeDirectory()
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let watchFile = incomingDirectory.appendingPathComponent("watch-recording.m4a")
        let bytes = CaptureTestAudio.validM4A
        try bytes.write(to: watchFile)
        let model = CaptureSessionModel()
        let receiver = WatchRelayStagingReceiver(sessionModel: model, stagingDirectory: stagingDirectory)

        let stagedURL = try receiver.receive(fileURL: watchFile)
        let itemID = try XCTUnwrap(model.stagedItems.first?.id)
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: RecordingDeliveryCoordinator())
        )
        await queue.deliver(itemID: itemID, to: captureFolder)

        XCTAssertEqual(model.stagedItems.count, 1)
        XCTAssertGreaterThan(model.stagedItems[0].duration, 0)
        XCTAssertTrue(model.stagedItems[0].wasRecoveredAfterRestart)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(
            try Data(contentsOf: captureFolder.appendingPathComponent(stagedURL.lastPathComponent)),
            bytes
        )
    }

    func testWatchDelegatePreservesTruncatedFileBeforeRejectingDelivery() async throws {
        let incomingDirectory = try makeDirectory()
        let stagingDirectory = try makeDirectory()
        let watchFile = incomingDirectory.appendingPathComponent("callback-lifetime.m4a")
        let bytes = CaptureTestAudio.truncatedM4A
        try bytes.write(to: watchFile)
        let model = CaptureSessionModel()
        let receiver = WatchRelayReceiver(sessionModel: model, stagingDirectory: stagingDirectory)

        XCTAssertTrue(receiver.receiveIncomingFile(at: watchFile))
        try FileManager.default.removeItem(at: watchFile)

        let stagedURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: stagingDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(try Data(contentsOf: stagedURL), bytes)

        await waitForWatchRelayRegistration(model)
        XCTAssertTrue(model.stagedItems.isEmpty)
        XCTAssertEqual(model.recoveryFailures.map(\.url), [stagedURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(receiver.lastReceiveError?.contains("complete, decodable audio") == true)
    }

    func testPhoneRelaunchKeepsInvalidWatchBytesOutOfDeliveryQueue() throws {
        let incomingDirectory = try makeDirectory()
        let stagingDirectory = try makeDirectory()
        let watchFile = incomingDirectory.appendingPathComponent("watch-truncated.m4a")
        try CaptureTestAudio.truncatedM4A.write(to: watchFile)
        let callbackModel = CaptureSessionModel()
        let receiver = WatchRelayReceiver(
            sessionModel: callbackModel,
            stagingDirectory: stagingDirectory
        )

        XCTAssertTrue(receiver.receiveIncomingFile(at: watchFile))
        let stagedURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: stagingDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        let relaunchedModel = CaptureSessionModel()
        _ = CaptureRecorder(
            sessionModel: relaunchedModel,
            writer: InertCaptureWriter(),
            stagingDirectory: stagingDirectory,
            deviceShortID: "test-device",
            observeInterruptions: false
        )

        XCTAssertTrue(relaunchedModel.stagedItems.isEmpty)
        XCTAssertEqual(relaunchedModel.recoveryFailures.map(\.url), [stagedURL])
        XCTAssertEqual(try Data(contentsOf: stagedURL), CaptureTestAudio.truncatedM4A)
    }

    func testWatchRelayStartupActivatesReceiverBeforeAuthOrVaultUI() {
        let receiver = StartupWatchRelayReceiver()

        _ = WatchRelayStartup(receiver: receiver)

        XCTAssertEqual(receiver.activationCount, 1)
    }
}

extension CaptureDeliveryTests {
    func testRebuildKeepsUnverifiableMediaOutOfDeliveryQueue() throws {
        let stagingDirectory = try makeDirectory()
        let validURL = stagingDirectory.appendingPathComponent("valid.m4a")
        let invalidURL = stagingDirectory.appendingPathComponent("invalid.m4a")
        try Data("valid".utf8).write(to: validURL)
        try Data("invalid".utf8).write(to: invalidURL)
        let model = CaptureSessionModel()
        _ = CaptureRecorder(
            sessionModel: model,
            writer: InertCaptureWriter(),
            stagingDirectory: stagingDirectory,
            deviceShortID: "test-device",
            observeInterruptions: false,
            mediaValidator: FilenameCaptureMediaValidator(validFilename: validURL.lastPathComponent)
        )

        XCTAssertEqual(model.stagedItems.map(\.url), [validURL])
        XCTAssertEqual(model.recoveryFailures.map(\.url), [invalidURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidURL.path))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStagedModel(url: URL) -> CaptureSessionModel {
        let model = CaptureSessionModel()
        XCTAssertTrue(model.transition(to: .recording))
        XCTAssertTrue(model.transition(to: .finalizing))
        XCTAssertTrue(model.stageCurrentItem(url: url, duration: 2, capturedAt: Date()))
        return model
    }

    private func waitForWatchRelayRegistration(_ model: CaptureSessionModel) async {
        for _ in 0..<20 where model.recoveryFailures.isEmpty {
            await Task.yield()
        }
    }
}

private final class StartupWatchRelayReceiver: WatchRelayActivating {
    private(set) var activationCount = 0

    func activate() { activationCount += 1 }
}

private enum InjectedDeliveryError: LocalizedError {
    case failed

    var errorDescription: String? { "Injected provider failure" }
}

private final class RecordingDeliveryCoordinator: CaptureDeliveryCoordinating {
    private(set) var writeCount = 0
    private(set) var lastFolderURL: URL?

    func coordinateWrite(in folderURL: URL, operation: (URL) throws -> Void) throws {
        writeCount += 1
        lastFolderURL = folderURL
        try operation(folderURL)
    }
}

private struct MidCopyFailingBytesCopier: CaptureBytesCopying {
    func copy(from sourceURL: URL, to destinationURL: URL) throws {
        try Data("partial".utf8).write(to: destinationURL)
        throw InjectedDeliveryError.failed
    }
}

private struct SameLengthCorruptingBytesCopier: CaptureBytesCopying {
    func copy(from sourceURL: URL, to destinationURL: URL) throws {
        var bytes = try Data(contentsOf: sourceURL)
        guard !bytes.isEmpty else { throw InjectedDeliveryError.failed }
        bytes[bytes.startIndex] ^= 0xFF
        try bytes.write(to: destinationURL)
    }
}

private final class RecordingBytesCopier: CaptureBytesCopying {
    private(set) var copyCount = 0

    func copy(from sourceURL: URL, to destinationURL: URL) throws {
        copyCount += 1
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

private struct AlwaysFailingFilePlacer: CaptureFilePlacing {
    func place(stagedURL: URL, in folderURL: URL) throws -> URL {
        throw InjectedDeliveryError.failed
    }
}

private final class RejectingSidecarWriter: CaptureSidecarWriting {
    private(set) var writeCount = 0

    func write(sidecar: CaptureTimeMetadataSidecar, alongside audioURL: URL) throws {
        writeCount += 1
        XCTFail("Recovered audio without capture facts must not synthesize a sidecar")
    }
}

private struct AlwaysValidCaptureMediaValidator: CaptureMediaValidating {
    func validate(url: URL) -> Result<ValidatedCaptureMedia, CaptureMediaValidationFailure> {
        .success(ValidatedCaptureMedia(duration: 2))
    }
}

private struct FilenameCaptureMediaValidator: CaptureMediaValidating {
    let validFilename: String

    func validate(url: URL) -> Result<ValidatedCaptureMedia, CaptureMediaValidationFailure> {
        url.lastPathComponent == validFilename
            ? .success(ValidatedCaptureMedia(duration: 2))
            : .failure(.invalidOrUnverifiableMedia)
    }
}

@MainActor
private final class InertCaptureWriter: CaptureFileWriting {
    func start(
        url: URL,
        generation: UInt64,
        onTerminal: @escaping @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ) throws {}

    func pause() {}
    func resume() throws {}
    func stop(generation: UInt64) throws {}
    func forceTerminate(generation: UInt64) throws {}
}
