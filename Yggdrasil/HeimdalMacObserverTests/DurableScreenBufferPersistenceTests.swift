import CryptoKit
import Foundation
import XCTest
@testable import HeimdalMacObserver

final class DurableScreenBufferPersistenceTests: XCTestCase {
    func testPreReplacementFailureRestoresMemoryAndLeavesCommittedFileUntouched() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = ScreenControlBinding(vaultIdentifier: "vault-1", localInstanceIdentifier: "instance-1")
        let first = ScreenQueueEntry(
            appIdentifier: "com.example.Editor",
            binding: binding,
            payload: Data("first".utf8)
        )
        let second = ScreenQueueEntry(
            appIdentifier: "com.example.Editor",
            binding: binding,
            payload: Data("second".utf8)
        )
        let initialBuffer = try DurableScreenBuffer(directoryURL: directory)
        try await initialBuffer.enqueue(first, maximum: 4)

        let queueURL = directory.appendingPathComponent("screen-buffer.json")
        let originalFile = try Data(contentsOf: queueURL)
        let failingBuffer = try DurableScreenBuffer(
            directoryURL: directory,
            fileWriter: FaultInjectingScreenQueueFileWriter(failurePoint: .beforeReplacement)
        )

        do {
            try await failingBuffer.enqueue(second, maximum: 4)
            XCTFail("A failure before replacement must reject the queue update.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Injected failure before atomic replacement.")
        }

        let inMemoryIdentities = await failingBuffer.identities()
        let diskData = try Data(contentsOf: queueURL)
        let reloadedBuffer = try DurableScreenBuffer(directoryURL: directory)
        let reloadedIdentities = await reloadedBuffer.identities()
        XCTAssertEqual(inMemoryIdentities, [first.contentIdentity])
        XCTAssertEqual(diskData, originalFile)
        XCTAssertEqual(reloadedIdentities, [first.contentIdentity])
    }

    func testPostReplacementErrorKeepsMemoryAndFileOnCommittedSnapshot() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = ScreenControlBinding(vaultIdentifier: "vault-1", localInstanceIdentifier: "instance-1")
        let first = ScreenQueueEntry(
            appIdentifier: "com.example.Editor",
            binding: binding,
            payload: Data("first".utf8)
        )
        let second = ScreenQueueEntry(
            appIdentifier: "com.example.Editor",
            binding: binding,
            payload: Data("second".utf8)
        )
        let initialBuffer = try DurableScreenBuffer(directoryURL: directory)
        try await initialBuffer.enqueue(first, maximum: 4)

        let committedBuffer = try DurableScreenBuffer(
            directoryURL: directory,
            fileWriter: FaultInjectingScreenQueueFileWriter(failurePoint: .afterReplacement)
        )
        try await committedBuffer.enqueue(second, maximum: 4)

        let identitiesAfterEnqueue = await committedBuffer.identities()
        let reloadedAfterEnqueue = try DurableScreenBuffer(directoryURL: directory)
        let diskIdentitiesAfterEnqueue = await reloadedAfterEnqueue.identities()
        XCTAssertEqual(identitiesAfterEnqueue, [first.contentIdentity, second.contentIdentity])
        XCTAssertEqual(diskIdentitiesAfterEnqueue, identitiesAfterEnqueue)

        try await committedBuffer.acknowledgeOldest(contentIdentity: first.contentIdentity)
        let identitiesAfterAcknowledgement = await committedBuffer.identities()
        let reloadedAfterAcknowledgement = try DurableScreenBuffer(directoryURL: directory)
        let diskIdentitiesAfterAcknowledgement = await reloadedAfterAcknowledgement.identities()
        XCTAssertEqual(identitiesAfterAcknowledgement, [second.contentIdentity])
        XCTAssertEqual(diskIdentitiesAfterAcknowledgement, identitiesAfterAcknowledgement)

        let queueURL = directory.appendingPathComponent("screen-buffer.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: queueURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testLegacyQueueSnapshotMigratesToHostReadableFrameBeforeBackfill() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let appIdentifier = "com.example.Editor"
        let binding = ScreenControlBinding(vaultIdentifier: "vault-1", localInstanceIdentifier: "instance-1")
        let appName = "Åpp"
        let windowTitle = "Döc.md"
        let frame = Data("abc".utf8).base64EncodedString()
        let legacyEntry = try makeLegacyQueueEntry(
            appIdentifier: appIdentifier,
            binding: binding,
            appName: appName,
            windowTitle: windowTitle,
            frame: frame
        )
        let snapshot = try JSONSerialization.data(
            withJSONObject: ["entries": [legacyEntry], "oldestEvictionCount": 0]
        )
        let queueURL = directory.appendingPathComponent("screen-buffer.json")
        try snapshot.write(to: queueURL, options: .atomic)

        let buffer = try DurableScreenBuffer(directoryURL: directory)
        let decodedEntry = await buffer.firstEntry()
        let restoredEntry = try XCTUnwrap(decodedEntry)
        try assertLegacyPayloadMigrated(
            restoredEntry,
            appIdentifier: appIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            frame: frame
        )
        let identities = await buffer.identities()
        XCTAssertEqual(identities, [restoredEntry.contentIdentity])

        try await buffer.acknowledgeOldest(contentIdentity: restoredEntry.contentIdentity)
        let identitiesAfterAcknowledgement = await buffer.identities()
        XCTAssertTrue(identitiesAfterAcknowledgement.isEmpty)
    }

    private func makeLegacyQueueEntry(
        appIdentifier: String,
        binding: ScreenControlBinding,
        appName: String,
        windowTitle: String,
        frame: String
    ) throws -> [String: Any] {
        let payload = try JSONEncoder().encode(
            LegacyScreenCaptureBundle(
                sensor: ScreenSensorIdentity(machine: "test-machine"),
                raw: LegacyScreenRawFrame(
                    capturedAt: "2026-10-25T07:15:30.000Z",
                    cadenceSeconds: 12.5,
                    appIdentifier: appIdentifier,
                    appName: appName,
                    windowIdentifier: 42,
                    windowTitle: windowTitle,
                    framePNGBase64: frame
                )
            )
        )
        let legacyBundle = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let legacyRaw = try XCTUnwrap(legacyBundle["raw"] as? [String: Any])
        XCTAssertEqual(legacyBundle["bundle_shape"] as? String, "raw_capture_bundle")
        XCTAssertEqual(legacyBundle["scope"] as? String, "screen_always_on")
        XCTAssertEqual(legacyRaw["app_name"] as? String, appName)
        XCTAssertEqual(legacyRaw["frame_png_base64"] as? String, frame)

        let legacyContext = [appIdentifier, binding.vaultIdentifier, binding.localInstanceIdentifier]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        let digest = SHA256.hash(data: Data(legacyContext.utf8) + payload)
        let legacyIdentity = digest.map { String(format: "%02x", $0) }.joined()
        return [
            "content_identity": legacyIdentity,
            "app_identifier": appIdentifier,
            "binding": [
                "vaultIdentifier": binding.vaultIdentifier,
                "localInstanceIdentifier": binding.localInstanceIdentifier
            ],
            "payload": payload.base64EncodedString()
        ]
    }

    private func assertLegacyPayloadMigrated(
        _ entry: ScreenQueueEntry,
        appIdentifier: String,
        appName: String,
        windowTitle: String,
        frame: String
    ) throws {
        XCTAssertEqual(
            entry.contentIdentity,
            "4d40ef77cca7ca657fde73e78e9bc0e5de9df4971adad879bf090b872ad2d6fa"
        )
        let bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: entry.payload) as? [String: Any])
        let raw = try XCTUnwrap(bundle["raw"] as? [String: Any])
        XCTAssertEqual(raw["app"] as? String, appName)
        XCTAssertEqual(raw["app_bundle_id"] as? String, appIdentifier)
        XCTAssertEqual(raw["captured_at"] as? String, "2026-10-25T07:15:30.000Z")
        XCTAssertEqual(raw["cadence_seconds"] as? Double, 12.5)
        XCTAssertEqual(raw["frame"] as? String, frame)
        XCTAssertEqual(raw["scope"] as? String, "screen_always_on")
        XCTAssertEqual(raw["window"] as? String, windowTitle)
        XCTAssertEqual(raw["window_id"] as? Int, 42)
        XCTAssertNil(raw["app_name"])
        XCTAssertNil(raw["frame_png_base64"])
        XCTAssertNil(raw["window_title"])
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

// Mirrors the ScreenRawFrame/ScreenCaptureBundle schema stored by the pre-migration client.
private struct LegacyScreenRawFrame: Encodable {
    let modality = "screen"
    let capturedAt: String
    let cadenceSeconds: TimeInterval
    let appIdentifier: String
    let appName: String
    let windowIdentifier: UInt32
    let windowTitle: String?
    let framePNGBase64: String

    enum CodingKeys: String, CodingKey {
        case modality
        case capturedAt = "captured_at"
        case cadenceSeconds = "cadence_seconds"
        case appIdentifier = "app_bundle_id"
        case appName = "app_name"
        case windowIdentifier = "window_id"
        case windowTitle = "window_title"
        case framePNGBase64 = "frame_png_base64"
    }
}

private struct LegacyScreenCaptureBundle: Encodable {
    let sensor: ScreenSensorIdentity
    let scope = "screen_always_on"
    let captureChain = ["screen_capture_post", "heimdal_macos_screen_observer"]
    let bundleShape = "raw_capture_bundle"
    let raw: LegacyScreenRawFrame

    enum CodingKeys: String, CodingKey {
        case sensor
        case scope
        case captureChain = "capture_chain"
        case bundleShape = "bundle_shape"
        case raw
    }
}

private struct FaultInjectingScreenQueueFileWriter: ScreenQueueFileWriting {
    enum FailurePoint: Sendable {
        case beforeReplacement
        case afterReplacement
    }

    let failurePoint: FailurePoint

    func replaceAtomically(_ data: Data, at destinationURL: URL, fileManager: FileManager) throws {
        switch failurePoint {
        case .beforeReplacement:
            throw ScreenQueueFileWriteError.beforeReplacement(FaultInjectedPersistenceError.beforeReplacement)
        case .afterReplacement:
            try AtomicScreenQueueFileWriter().replaceAtomically(
                data,
                at: destinationURL,
                fileManager: fileManager
            )
            throw ScreenQueueFileWriteError.afterReplacement(FaultInjectedPersistenceError.afterReplacement)
        }
    }
}

private enum FaultInjectedPersistenceError: LocalizedError, Sendable {
    case beforeReplacement
    case afterReplacement

    var errorDescription: String? {
        switch self {
        case .beforeReplacement:
            "Injected failure before atomic replacement."
        case .afterReplacement:
            "Injected report after atomic replacement."
        }
    }
}
