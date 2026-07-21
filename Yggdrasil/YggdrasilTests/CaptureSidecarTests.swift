import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureSidecarTests: XCTestCase {
    func testSidecarWrittenAfterAudioWithSessionFields() async throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let source = stagingDirectory.appendingPathComponent("heimdal-session.m4a")
        try Data("complete recording".utf8).write(to: source)
        let start = Date(timeIntervalSince1970: 1_783_493_331)
        let end = start.addingTimeInterval(449)
        let model = makeStagedModel(
            url: source,
            start: start,
            end: end,
            interruptions: 1,
            deviceID: "heimdal-device-42"
        )
        let itemID = try XCTUnwrap(model.stagedItems.first?.id)
        let sidecarWriter = RecordingSidecarWriter()
        let queue = CaptureDeliveryQueue(
            sessionModel: model,
            placer: CaptureDeliveryFilePlacer(coordinator: ImmediateCoordinator()),
            sidecarWriter: sidecarWriter
        )

        await queue.deliver(itemID: itemID, to: captureFolder)

        let audioURL = captureFolder.appendingPathComponent(source.lastPathComponent)
        let sidecarURL = captureFolder.appendingPathComponent("\(source.lastPathComponent).capture.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertTrue(sidecarWriter.sawFinalAudio)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            CaptureTimeMetadataSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        XCTAssertEqual(decoded.sidecarVersion, 1)
        XCTAssertEqual(decoded.deviceID, "heimdal-device-42")
        XCTAssertEqual(decoded.recordedStartAt, start)
        XCTAssertEqual(decoded.recordedEndAt, end)
        XCTAssertEqual(decoded.interruptions, 1)
        XCTAssertEqual(decoded.sourceSurface, .iphoneApp)
        XCTAssertNil(decoded.location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testLocationOmittedByDefault() throws {
        let item = CaptureSessionModel.StagedItem(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/heimdal.m4a"),
            duration: 3,
            capturedAt: Date(),
            recordedStartAt: Date(),
            recordedEndAt: Date(),
            interruptions: 0,
            deviceID: "device",
            sourceSurface: .iphoneApp,
            wasRecoveredAfterRestart: false,
            deliveryState: .staged
        )

        let sidecar = CaptureTimeMetadataSidecar(item: item, settings: .microphoneOnly)
        let data = try JSONEncoder().encode(sidecar)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(sidecar.location)
        XCTAssertNil(json["location"])
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStagedModel(
        url: URL,
        start: Date,
        end: Date,
        interruptions: Int,
        deviceID: String
    ) -> CaptureSessionModel {
        let model = CaptureSessionModel()
        XCTAssertTrue(model.transition(to: .recording))
        XCTAssertTrue(model.transition(to: .finalizing))
        XCTAssertTrue(model.stageCurrentItem(
            url: url,
            duration: end.timeIntervalSince(start),
            capturedAt: start,
            recordedStartAt: start,
            recordedEndAt: end,
            interruptions: interruptions,
            deviceID: deviceID
        ))
        return model
    }
}

private final class ImmediateCoordinator: CaptureDeliveryCoordinating {
    func coordinateWrite(in folderURL: URL, operation: (URL) throws -> Void) throws {
        try operation(folderURL)
    }
}

private final class RecordingSidecarWriter: CaptureSidecarWriting {
    private(set) var sawFinalAudio = false
    private let writer = CaptureSidecarWriter(coordinator: ImmediateCoordinator())

    func write(sidecar: CaptureTimeMetadataSidecar, alongside audioURL: URL) throws {
        sawFinalAudio = FileManager.default.fileExists(atPath: audioURL.path)
        try writer.write(sidecar: sidecar, alongside: audioURL)
    }
}
