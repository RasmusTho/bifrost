import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class WatchRelaySidecarTests: XCTestCase {
    func testWatchRelayMetadataProducesCaptureSidecarFromRealIngress() async throws {
        let incomingDirectory = try makeDirectory()
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let watchFile = incomingDirectory.appendingPathComponent("watch-session.m4a")
        try CaptureTestAudio.validM4A.write(to: watchFile)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(42)
        let metadata = WatchRelayCaptureMetadata(
            recordedStartAt: start,
            recordedEndAt: end,
            timezone: "Europe/Stockholm",
            interruptions: 2
        )
        let model = CaptureSessionModel()
        let receiver = WatchRelayReceiver(
            sessionModel: model,
            stagingDirectory: stagingDirectory,
            deviceID: "registered-phone-device"
        )

        XCTAssertTrue(receiver.receiveIncomingFile(
            at: watchFile,
            transferMetadata: try metadata.transferMetadata()
        ))
        try FileManager.default.removeItem(at: watchFile)
        for _ in 0..<20 where model.stagedItems.isEmpty {
            await Task.yield()
        }
        let item = try XCTUnwrap(model.stagedItems.first)
        let stagedURL = item.url
        XCTAssertEqual(item.captureMetadata?.deviceID, "registered-phone-device")
        XCTAssertEqual(item.captureMetadata?.recordedStartAt, start)
        XCTAssertEqual(item.captureMetadata?.recordedEndAt, end)
        XCTAssertEqual(item.captureMetadata?.timezone, "Europe/Stockholm")
        XCTAssertEqual(item.captureMetadata?.interruptions, 2)
        XCTAssertEqual(item.captureMetadata?.sourceSurface, .watchRelay)

        let coordinator = ImmediateDeliveryCoordinator()
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: coordinator),
            sidecarWriter: CaptureSidecarWriter(coordinator: coordinator)
        )
        await queue.deliver(itemID: item.id, to: captureFolder)

        let sidecarURL = captureFolder.appendingPathComponent(
            "\(stagedURL.lastPathComponent).capture.json"
        )
        try assertSidecar(at: sidecarURL, start: start, end: end, interruptions: 2)
    }

    func testCallbackDurablyStagesMetadataForRelaunchBeforeRegistrationTask() async throws {
        let incomingDirectory = try makeDirectory()
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let watchFile = incomingDirectory.appendingPathComponent("watch-relaunch.m4a")
        try CaptureTestAudio.validM4A.write(to: watchFile)
        let start = Date(timeIntervalSince1970: 1_700_100_000)
        let end = start.addingTimeInterval(30)
        let metadata = WatchRelayCaptureMetadata(
            recordedStartAt: start,
            recordedEndAt: end,
            timezone: "Europe/Stockholm",
            interruptions: 1
        )
        let callbackModel = CaptureSessionModel()
        let receiver = WatchRelayReceiver(
            sessionModel: callbackModel,
            stagingDirectory: stagingDirectory,
            deviceID: "registered-phone-device"
        )

        XCTAssertTrue(receiver.receiveIncomingFile(
            at: watchFile,
            transferMetadata: try metadata.transferMetadata()
        ))
        let stagedURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: stagingDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "m4a" }
        )
        let metadataURL = WatchRelayMetadataStore().metadataURL(for: stagedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))

        let relaunchedModel = CaptureSessionModel()
        _ = CaptureRecorder(
            sessionModel: relaunchedModel,
            stagingDirectory: stagingDirectory,
            deviceID: "registered-phone-device",
            observeInterruptions: false
        )
        let item = try XCTUnwrap(relaunchedModel.stagedItems.first)
        XCTAssertEqual(item.captureMetadata?.recordedStartAt, start)
        XCTAssertEqual(item.captureMetadata?.sourceSurface, .watchRelay)

        let sidecarURL = try await deliver(item: item, model: relaunchedModel, to: captureFolder)
        try assertSidecar(at: sidecarURL, start: start, end: end, interruptions: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    private func deliver(
        item: CaptureSessionModel.StagedItem,
        model: CaptureSessionModel,
        to captureFolder: URL
    ) async throws -> URL {
        let coordinator = ImmediateDeliveryCoordinator()
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: coordinator),
            sidecarWriter: CaptureSidecarWriter(coordinator: coordinator)
        )
        await queue.deliver(itemID: item.id, to: captureFolder)
        return captureFolder.appendingPathComponent("\(item.url.lastPathComponent).capture.json")
    }

    private func assertSidecar(
        at url: URL,
        start: Date,
        end: Date,
        interruptions: Int
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(
            CaptureTimeMetadataSidecar.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(sidecar.deviceID, "registered-phone-device")
        XCTAssertEqual(sidecar.sourceSurface, .watchRelay)
        XCTAssertEqual(sidecar.recordedStartAt, start)
        XCTAssertEqual(sidecar.recordedEndAt, end)
        XCTAssertEqual(sidecar.interruptions, interruptions)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct ImmediateDeliveryCoordinator: CaptureDeliveryCoordinating {
    func coordinateWrite(in folderURL: URL, operation: (URL) throws -> Void) throws {
        try operation(folderURL)
    }
}
