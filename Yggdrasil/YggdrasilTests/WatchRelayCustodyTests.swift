import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class WatchRelayCustodyTests: XCTestCase {
    func testDeleteOnlyOnConfirmedTransfer() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("watch.m4a")
        try CaptureTestAudio.validM4A.write(to: fileURL)
        let transfer = WatchRelayTransfer(identifier: UUID())
        let transport = FakeWatchRelayTransport(transfer: transfer)
        let custody = WatchRelayCustody()

        XCTAssertTrue(custody.enqueue(fileURL: fileURL, using: transport))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(custody.queuedFiles, [fileURL])

        custody.complete(transfer: transfer, error: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(custody.queuedFiles.isEmpty)
    }

    func testFailedTransferStaysQueued() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("watch.m4a")
        try CaptureTestAudio.validM4A.write(to: fileURL)
        let transfer = WatchRelayTransfer(identifier: UUID())
        let custody = WatchRelayCustody()

        XCTAssertTrue(custody.enqueue(fileURL: fileURL, using: FakeWatchRelayTransport(transfer: transfer)))
        custody.complete(transfer: transfer, error: FakeRelayError.failed)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(custody.queuedFiles, [fileURL])
        XCTAssertNotNil(custody.lastError)
    }

    func testRelaunchReenqueuesProductionValidMediaNotAlreadyOutstanding() throws {
        let directory = try makeDirectory()
        let first = directory.appendingPathComponent("first.m4a")
        let second = directory.appendingPathComponent("second.m4a")
        try CaptureTestAudio.validM4A.write(to: first)
        try CaptureTestAudio.validM4A.write(to: second)
        let transport = RecordingWatchRelayTransport()
        let custody = WatchRelayCustody()

        custody.reconcileQueue(from: directory, using: transport)

        XCTAssertEqual(Set(transport.transferredURLs), Set([first, second]))
        XCTAssertEqual(Set(custody.queuedFiles), Set([first, second]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRelaunchKeepsOfflineFilesUntilAReachableRetryIsQueued() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("offline.m4a")
        try CaptureTestAudio.validM4A.write(to: fileURL)
        let custody = WatchRelayCustody()

        custody.reconcileQueue(from: directory, using: OfflineWatchRelayTransport())

        XCTAssertEqual(custody.queuedFiles, [fileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNotNil(custody.lastError)

        let reachableTransport = RecordingWatchRelayTransport()
        custody.reconcileQueue(from: directory, using: reachableTransport)

        XCTAssertEqual(reachableTransport.transferredURLs, [fileURL])
        XCTAssertEqual(custody.queuedFiles, [fileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRelaunchRetainsOutstandingTransferUntilItsConfirmedCompletion() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("outstanding.m4a")
        try CaptureTestAudio.validM4A.write(to: fileURL)
        let transport = RecordingWatchRelayTransport(outstandingURLs: [fileURL])
        let custody = WatchRelayCustody()

        custody.reconcileQueue(from: directory, using: transport)

        XCTAssertTrue(transport.transferredURLs.isEmpty)
        XCTAssertEqual(custody.queuedFiles, [fileURL])
        custody.complete(
            transfer: WatchRelayTransfer(identifier: UUID(), fileURL: fileURL),
            error: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(custody.queuedFiles.isEmpty)
    }

    func testWatchFinalizationNeverEnqueuesInvalidMedia() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("corrupt.m4a")
        let invalidBytes = Data("not audio".utf8)
        try invalidBytes.write(to: fileURL)
        let transport = RecordingWatchRelayTransport()
        let custody = WatchRelayCustody()

        XCTAssertFalse(custody.enqueue(fileURL: fileURL, using: transport))

        XCTAssertTrue(transport.transferredURLs.isEmpty)
        XCTAssertTrue(custody.queuedFiles.isEmpty)
        XCTAssertEqual(custody.invalidFiles, [fileURL])
        XCTAssertEqual(try Data(contentsOf: fileURL), invalidBytes)
        XCTAssertTrue(custody.lastError?.contains("kept a recording") == true)
    }

    func testWatchRelaunchPreservesTruncatedMediaWithoutRelay() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("truncated.m4a")
        try CaptureTestAudio.truncatedM4A.write(to: fileURL)
        let transport = RecordingWatchRelayTransport()
        let custody = WatchRelayCustody()

        custody.reconcileQueue(from: directory, using: transport)

        XCTAssertTrue(transport.transferredURLs.isEmpty)
        XCTAssertTrue(custody.queuedFiles.isEmpty)
        XCTAssertEqual(custody.invalidFiles, [fileURL])
        XCTAssertEqual(try Data(contentsOf: fileURL), CaptureTestAudio.truncatedM4A)
        XCTAssertNotNil(custody.lastError)
    }

    func testRelayCarriesPersistedCaptureMetadataAndDeletesItOnlyAfterConfirmation() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("metadata.m4a")
        try CaptureTestAudio.validM4A.write(to: fileURL)
        let metadata = WatchRelayCaptureMetadata(
            recordedStartAt: Date(timeIntervalSince1970: 1_700_000_000),
            recordedEndAt: Date(timeIntervalSince1970: 1_700_000_020),
            timezone: "Europe/Stockholm",
            interruptions: 1
        )
        let store = WatchRelayMetadataStore()
        try store.write(metadata, for: fileURL)
        let transport = RecordingWatchRelayTransport()
        let custody = WatchRelayCustody(metadataStore: store)

        XCTAssertTrue(custody.enqueue(fileURL: fileURL, using: transport))
        XCTAssertEqual(transport.transferredMetadata, [metadata])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.metadataURL(for: fileURL).path))

        custody.complete(
            transfer: WatchRelayTransfer(identifier: transport.transferIDs[0], fileURL: fileURL),
            error: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.metadataURL(for: fileURL).path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class FakeWatchRelayTransport: WatchRelayTransferring {
    let transfer: WatchRelayTransfer

    init(transfer: WatchRelayTransfer) { self.transfer = transfer }
    func transfer(
        fileURL: URL,
        metadata: WatchRelayCaptureMetadata?
    ) throws -> WatchRelayTransfer { transfer }
    func outstandingFileURLs() -> Set<URL> { [] }
}

private final class RecordingWatchRelayTransport: WatchRelayTransferring {
    private let outstandingURLs: Set<URL>
    private(set) var transferredURLs: [URL] = []
    private(set) var transferredMetadata: [WatchRelayCaptureMetadata?] = []
    private(set) var transferIDs: [UUID] = []

    init(outstandingURLs: Set<URL> = []) {
        self.outstandingURLs = outstandingURLs
    }

    func transfer(
        fileURL: URL,
        metadata: WatchRelayCaptureMetadata?
    ) throws -> WatchRelayTransfer {
        transferredURLs.append(fileURL)
        transferredMetadata.append(metadata)
        let identifier = UUID()
        transferIDs.append(identifier)
        return WatchRelayTransfer(identifier: identifier, fileURL: fileURL)
    }

    func outstandingFileURLs() -> Set<URL> { outstandingURLs }
}

private struct OfflineWatchRelayTransport: WatchRelayTransferring {
    func transfer(
        fileURL: URL,
        metadata: WatchRelayCaptureMetadata?
    ) throws -> WatchRelayTransfer { throw FakeRelayError.failed }
    func outstandingFileURLs() -> Set<URL> { [] }
}

private enum FakeRelayError: LocalizedError {
    case failed
    var errorDescription: String? { "Injected relay failure" }
}
