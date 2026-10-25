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

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
