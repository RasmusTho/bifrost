import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureSidecarTests: XCTestCase {
    func testSidecarWrittenAfterAudioWithSessionFields() async throws {
        let stagingDirectory = try makeDirectory()
        let captureFolder = try makeDirectory()
        let start = Date(timeIntervalSince1970: 1_783_493_331)
        let end = start.addingTimeInterval(449)
        let model = CaptureSessionModel()
        let recorder = try makeRecorder(
            sessionModel: model, stagingDirectory: stagingDirectory, start: start, end: end
        )
        recorder.start()
        await recorder.handleInterruption(type: .began, shouldResume: false)
        await recorder.stop()

        let itemID = try XCTUnwrap(model.stagedItems.first?.id)
        let source = try XCTUnwrap(model.stagedItems.first?.url)
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
        XCTAssertEqual(decoded.deviceID, "2e54b80e-89da-433c-8a7d-6e6d1d4ec5b3")
        XCTAssertEqual(decoded.recordedStartAt, start)
        XCTAssertEqual(decoded.recordedEndAt, end)
        XCTAssertEqual(decoded.timezone, "Europe/Stockholm")
        XCTAssertEqual(decoded.interruptions, 1)
        XCTAssertEqual(decoded.sourceSurface, .watchRelay)
        XCTAssertNil(decoded.location)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sidecarURL)
        ) as? [String: Any])
        XCTAssertEqual(json["source_surface"] as? String, "watch-relay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testLocationOmittedByDefault() throws {
        let now = Date()
        let item = CaptureSessionModel.StagedItem(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/heimdal.m4a"),
            duration: 3,
            capturedAt: now,
            captureMetadata: CaptureSessionModel.CaptureMetadata(
                recordedStartAt: now,
                recordedEndAt: now,
                timezone: "Europe/Stockholm",
                interruptions: 0,
                deviceID: "device",
                sourceSurface: .iphoneApp
            ),
            wasRecoveredAfterRestart: false,
            deliveryState: .staged
        )

        let sidecar = try XCTUnwrap(
            CaptureTimeMetadataSidecar(item: item, settings: .microphoneOnly)
        )
        let data = try JSONEncoder().encode(sidecar)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(sidecar.location)
        XCTAssertNil(json["location"])
    }

    func testDeviceIdentityPersistsTheHCAP04DeviceID() throws {
        let suiteName = "HeimdalDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = HeimdalDeviceIdentity(defaults: defaults).deviceID()
        let second = HeimdalDeviceIdentity(defaults: defaults).deviceID()

        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: HeimdalDeviceIdentity.defaultsKey), first)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRecorder(
        sessionModel: CaptureSessionModel,
        stagingDirectory: URL,
        start: Date,
        end: Date
    ) throws -> CaptureRecorder {
        let clock = SidecarTestClock(values: [start, end])
        return CaptureRecorder(
            sessionModel: sessionModel,
            writer: SidecarCaptureWriter(),
            stagingDirectory: stagingDirectory,
            deviceID: "2e54b80e-89da-433c-8a7d-6e6d1d4ec5b3",
            deviceShortID: "local-file-token",
            sourceSurface: .watchRelay,
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm")),
            now: { clock.next() },
            observeInterruptions: false,
            mediaValidator: SidecarValidMediaValidator()
        )
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

@MainActor
private final class SidecarCaptureWriter: CaptureFileWriting {
    private var urls: [UInt64: URL] = [:]
    private var handlers: [UInt64: @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void] = [:]

    func start(
        url: URL,
        generation: UInt64,
        onTerminal: @escaping @MainActor @Sendable (CaptureFileWriterTerminalEvent) -> Void
    ) throws {
        try Data("complete recording".utf8).write(to: url)
        urls[generation] = url
        handlers[generation] = onTerminal
    }

    func pause() {}
    func resume() throws {}

    func stop(generation: UInt64) throws {
        handlers[generation]?(CaptureFileWriterTerminalEvent(generation: generation, result: .success(449)))
    }

    func forceTerminate(generation: UInt64) throws {
        handlers[generation]?(CaptureFileWriterTerminalEvent(generation: generation, result: .success(449)))
    }
}

private struct SidecarValidMediaValidator: CaptureMediaValidating {
    func validate(url: URL) -> Result<ValidatedCaptureMedia, CaptureMediaValidationFailure> {
        .success(ValidatedCaptureMedia(duration: 449))
    }
}

private final class SidecarTestClock {
    private var values: [Date]

    init(values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        values.removeFirst()
    }
}
