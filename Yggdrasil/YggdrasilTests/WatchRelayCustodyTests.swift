import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class WatchRelayCustodyTests: XCTestCase {
    func testDeleteOnlyOnConfirmedTransfer() throws {
        let directory = try makeDirectory()
        let fileURL = directory.appendingPathComponent("watch.m4a")
        try Data("memo".utf8).write(to: fileURL)
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
        try Data("memo".utf8).write(to: fileURL)
        let transfer = WatchRelayTransfer(identifier: UUID())
        let custody = WatchRelayCustody()

        XCTAssertTrue(custody.enqueue(fileURL: fileURL, using: FakeWatchRelayTransport(transfer: transfer)))
        custody.complete(transfer: transfer, error: FakeRelayError.failed)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(custody.queuedFiles, [fileURL])
        XCTAssertNotNil(custody.lastError)
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
    func transfer(fileURL: URL) throws -> WatchRelayTransfer { transfer }
}

private enum FakeRelayError: LocalizedError {
    case failed
    var errorDescription: String? { "Injected relay failure" }
}
