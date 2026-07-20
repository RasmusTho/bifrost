import XCTest
import YggdrasilCore
@testable import Yggdrasil

enum VaultFileStoreCoordinationOperation: Equatable {
    case read
    case write
}

final class RecordingCoordinator: VaultFileCoordinating, @unchecked Sendable {
    var operations: [VaultFileStoreCoordinationOperation] = []
    var beforeNextWrite: (@Sendable (URL) throws -> Void)?

    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        operations.append(.read)
        return try accessor(url)
    }

    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        operations.append(.write)
        if let beforeNextWrite {
            self.beforeNextWrite = nil
            try beforeNextWrite(url)
        }
        return try accessor(url)
    }
}

private final class DelayedCoordinator: VaultFileCoordinating, @unchecked Sendable {
    private let delay: TimeInterval
    private let failure: Error?
    private let lock = NSLock()
    private var accessedOnMainThread = false
    private var accessCount = 0
    var onAccessStarted: (@Sendable () -> Void)?

    init(delay: TimeInterval = 0.2, failure: Error? = nil) {
        self.delay = delay
        self.failure = failure
    }

    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        try performAccess { try accessor(url) }
    }

    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        try performAccess { try accessor(url) }
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accessedOnMainThread
    }

    var totalAccessCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessCount
    }

    private func performAccess<T: Sendable>(_ accessor: @Sendable () throws -> T) throws -> T {
        lock.lock()
        accessedOnMainThread = accessedOnMainThread || Thread.isMainThread
        accessCount += 1
        lock.unlock()
        onAccessStarted?()
        Thread.sleep(forTimeInterval: delay)
        if let failure { throw failure }
        return try accessor()
    }
}

private final class AlwaysStaleCoordinator: VaultFileCoordinating, @unchecked Sendable {
    private(set) var writeAttempts = 0

    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        try accessor(url)
    }

    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        writeAttempts += 1
        try "---\nexternal: \(writeAttempts)\n---\n".write(to: url, atomically: true, encoding: .utf8)
        return try accessor(url)
    }
}

private final class StaleOnceDelayedCoordinator: VaultFileCoordinating, @unchecked Sendable {
    private let replacement: String
    private let delay: TimeInterval
    private let lock = NSLock()
    private var writeCount = 0
    var onFirstWrite: (@Sendable () -> Void)?

    init(replacement: String, delay: TimeInterval = 0.2) {
        self.replacement = replacement
        self.delay = delay
    }

    func coordinateRead<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        try accessor(url)
    }

    func coordinateWrite<T: Sendable>(at url: URL, accessor: @Sendable (URL) throws -> T) throws -> T {
        lock.lock()
        writeCount += 1
        let isFirstWrite = writeCount == 1
        lock.unlock()

        if isFirstWrite {
            onFirstWrite?()
            Thread.sleep(forTimeInterval: delay)
            try replacement.write(to: url, atomically: true, encoding: .utf8)
        }
        return try accessor(url)
    }

    var totalWriteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCount
    }
}

private final class MutationValueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    func record(_ value: String) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}

private final class AtomicReadProbe: @unchecked Sendable {
    private let allowedSnapshots: Set<Data>
    private let lock = NSLock()
    private var stopped = false
    private var startedReaders = 0
    private var completedReads = 0
    private var firstInvalidObservation: String?

    init(allowedSnapshots: Set<Data>) {
        self.allowedSnapshots = allowedSnapshots
    }

    func readerStarted() {
        lock.lock()
        startedReaders += 1
        lock.unlock()
    }

    var readerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedReaders
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped
    }

    func inspect(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            lock.lock()
            completedReads += 1
            if !allowedSnapshots.contains(data), firstInvalidObservation == nil {
                firstInvalidObservation = "observed an unexpected \(data.count)-byte snapshot"
            }
            lock.unlock()
        } catch {
            lock.lock()
            if firstInvalidObservation == nil {
                firstInvalidObservation = "read failed during replacement: \(error)"
            }
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var result: (readCount: Int, invalidObservation: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (completedReads, firstInvalidObservation)
    }
}

final class VaultFileStoreTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YggdrasilVaultFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testWholeFileWriteIsAtomicReplace() async throws {
        let path = "notes/atomic.md"
        let directory = tempDirectory.appendingPathComponent("notes")
        let url = directory.appendingPathComponent("atomic.md")
        let oldText = "---\nversion: old\n---\n\n" + String(repeating: "o", count: 2_000_000)
        let newText = "---\nversion: new\n---\n\n" + String(repeating: "n", count: 2_000_000)
        var modifiedDocument = try FrontmatterDocument.parse(newText)
        modifiedDocument.frontmatter["replaced"] = .bool(true)
        let modifiedText = modifiedDocument.rendered()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try oldText.write(to: url, atomically: true, encoding: .utf8)

        let store = VaultFileStore(rootURL: tempDirectory)
        let probe = AtomicReadProbe(allowedSnapshots: Set([
            Data(oldText.utf8),
            Data(newText.utf8),
            Data(modifiedText.utf8)
        ]))
        let readers = (0..<4).map { _ in
            Task.detached {
                probe.readerStarted()
                while probe.shouldContinue {
                    probe.inspect(url)
                }
            }
        }
        defer { probe.stop() }
        while probe.readerCount < readers.count { await Task.yield() }

        for iteration in 0..<16 {
            try await store.write(iteration.isMultiple(of: 2) ? newText : oldText, to: path)
        }
        try await store.write(newText, to: path)

        try await store.readModifyWrite(path) { document in
            document.frontmatter["replaced"] = .bool(true)
        }
        probe.stop()
        for reader in readers { await reader.value }

        let observation = probe.result
        XCTAssertGreaterThan(observation.readCount, 0)
        XCTAssertNil(observation.invalidObservation, observation.invalidObservation ?? "")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), modifiedText)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["atomic.md"])
    }

    @MainActor
    func testRetryUsesInitiatingMutationSnapshotAfterCallerInputChanges() async throws {
        let path = "_heimdal/settings.md"
        let url = tempDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nbase: true\n---\n".write(to: url, atomically: true, encoding: .utf8)

        let firstWriteStarted = expectation(description: "first stale write started")
        let coordinator = StaleOnceDelayedCoordinator(replacement: "---\nbase: true\nexternal: fresh\n---\n")
        coordinator.onFirstWrite = { firstWriteStarted.fulfill() }
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)
        let recorder = MutationValueRecorder()
        var uiInput = "initiating-value"
        let initiatingValue = uiInput

        let task = Task {
            try await store.readModifyWrite(path) { document in
                recorder.record(initiatingValue)
                document.frontmatter["selection"] = .string(initiatingValue)
            }
        }
        await fulfillment(of: [firstWriteStarted], timeout: 1)
        uiInput = "changed-while-awaiting"
        try await task.value

        XCTAssertEqual(uiInput, "changed-while-awaiting")
        XCTAssertEqual(recorder.values, ["initiating-value", "initiating-value"])
        XCTAssertEqual(coordinator.totalWriteCount, 2)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("external: fresh"))
        XCTAssertTrue(text.contains("selection: initiating-value"))
        XCTAssertFalse(text.contains("changed-while-awaiting"))
    }

    func testPersistentStaleWritesExhaustRetryBudget() async throws {
        let path = "_heimdal/settings.md"
        let url = tempDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nbase: true\n---\n".write(to: url, atomically: true, encoding: .utf8)

        let coordinator = AlwaysStaleCoordinator()
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)

        do {
            try await store.readModifyWrite(path) { document in
                document.frontmatter["phone"] = .string("never-written")
            }
            XCTFail("expected bounded stale-write contention")
        } catch VaultFileStoreError.staleWriteContention(let stalePath) {
            XCTAssertEqual(stalePath, path)
        } catch {
            XCTFail("expected staleWriteContention, got \(error)")
        }
        XCTAssertEqual(coordinator.writeAttempts, 3)
    }

    @MainActor
    func testMainActorPublicPathsUseBackgroundCoordinatorAndPropagateErrors() async throws {
        let path = "notes/example.md"
        let directory = tempDirectory.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nvalue: initial\n---\n".write(
            to: directory.appendingPathComponent("example.md"),
            atomically: true,
            encoding: .utf8
        )

        let readCoordinator = DelayedCoordinator()
        let readStore = VaultFileStore(rootURL: tempDirectory, coordinator: readCoordinator)
        _ = try await assertRunsOffMain(readCoordinator) { try await readStore.read(path) }

        let listCoordinator = DelayedCoordinator()
        let listStore = VaultFileStore(rootURL: tempDirectory, coordinator: listCoordinator)
        _ = try await assertRunsOffMain(listCoordinator) { try await listStore.listEntries(in: "notes") }

        let manyCoordinator = DelayedCoordinator()
        let manyStore = VaultFileStore(rootURL: tempDirectory, coordinator: manyCoordinator)
        _ = try await assertRunsOffMain(manyCoordinator) { await manyStore.readMany([path]) }

        let writeCoordinator = DelayedCoordinator()
        let writeStore = VaultFileStore(rootURL: tempDirectory, coordinator: writeCoordinator)
        _ = try await assertRunsOffMain(writeCoordinator) {
            try await writeStore.write("---\nvalue: written\n---\n", to: path)
        }

        let modifyCoordinator = DelayedCoordinator()
        let modifyStore = VaultFileStore(rootURL: tempDirectory, coordinator: modifyCoordinator)
        _ = try await assertRunsOffMain(modifyCoordinator, expectedAccessCount: 2) {
            try await modifyStore.readModifyWrite(path) { document in
                document.frontmatter["value"] = .string("modified")
            }
        }

        let failingCoordinator = DelayedCoordinator(failure: CocoaError(.fileReadNoPermission))
        let failingStore = VaultFileStore(rootURL: tempDirectory, coordinator: failingCoordinator)
        do {
            _ = try await assertRunsOffMain(failingCoordinator) { try await failingStore.read(path) }
            XCTFail("expected delayed read error")
        } catch VaultFileStoreError.readFailed(_, _) {
            // Expected: the background coordinator error reaches the main-actor caller.
        }
    }

    @MainActor
    private func assertRunsOffMain<T>(
        _ coordinator: DelayedCoordinator,
        expectedAccessCount: Int = 1,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let started = expectation(description: "background coordination started")
        started.expectedFulfillmentCount = expectedAccessCount
        coordinator.onAccessStarted = { started.fulfill() }
        let task = Task { try await operation() }
        await fulfillment(of: [started], timeout: 1)

        let mainActorTurn = Task { @MainActor in true }
        let mainActorAdvanced = await mainActorTurn.value
        XCTAssertTrue(mainActorAdvanced)
        let value = try await task.value
        XCTAssertFalse(coordinator.ranOnMainThread)
        XCTAssertEqual(coordinator.totalAccessCount, expectedAccessCount)
        return value
    }
}
