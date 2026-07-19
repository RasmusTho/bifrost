import XCTest
import YggdrasilCore
@testable import Yggdrasil

private enum VaultFileStoreCoordinationOperation: Equatable {
    case read
    case write
}

private final class RecordingCoordinator: VaultFileCoordinating {
    var operations: [VaultFileStoreCoordinationOperation] = []
    var beforeNextWrite: ((URL) throws -> Void)?

    func coordinateRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        operations.append(.read)
        return try accessor(url)
    }

    func coordinateWrite<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        operations.append(.write)
        if let beforeNextWrite {
            self.beforeNextWrite = nil
            try beforeNextWrite(url)
        }
        return try accessor(url)
    }
}

private final class DelayedCoordinator: VaultFileCoordinating {
    private let delay: TimeInterval
    private let failure: Error?
    private let lock = NSLock()
    private var accessedOnMainThread = false
    var onAccessStarted: (() -> Void)?

    init(delay: TimeInterval = 0.2, failure: Error? = nil) {
        self.delay = delay
        self.failure = failure
    }

    func coordinateRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        try performAccess { try accessor(url) }
    }

    func coordinateWrite<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        try performAccess { try accessor(url) }
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accessedOnMainThread
    }

    private func performAccess<T>(_ accessor: () throws -> T) throws -> T {
        lock.lock()
        accessedOnMainThread = accessedOnMainThread || Thread.isMainThread
        lock.unlock()
        onAccessStarted?()
        Thread.sleep(forTimeInterval: delay)
        if let failure { throw failure }
        return try accessor()
    }
}

private final class AlwaysStaleCoordinator: VaultFileCoordinating {
    private(set) var writeAttempts = 0

    func coordinateRead<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        try accessor(url)
    }

    func coordinateWrite<T>(at url: URL, accessor: (URL) throws -> T) throws -> T {
        writeAttempts += 1
        try "---\nexternal: \(writeAttempts)\n---\n".write(to: url, atomically: true, encoding: .utf8)
        return try accessor(url)
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

    func testWriteThenReadRoundTrips() async throws {
        let store = VaultFileStore(rootURL: tempDirectory)
        try await store.write("---\nfoo: bar\n---\n\nBody.\n", to: "_heimdal/settings.md")
        let text = try await store.read("_heimdal/settings.md")
        XCTAssertTrue(text.contains("foo: bar"))
    }

    func testReadModifyWriteCreatesNoteWhenMissing() async throws {
        let store = VaultFileStore(rootURL: tempDirectory)
        try await store.readModifyWrite("_heimdal/interests.md") { document in
            document.frontmatter["weights"] = .map({
                var map = YAMLMap()
                map["reading"] = .double(0.5)
                return map
            }())
        }
        let text = try await store.read("_heimdal/interests.md")
        XCTAssertTrue(text.contains("weights:"))
        XCTAssertTrue(text.contains("reading: 0.5"))
    }

    func testListEntriesReturnsFoldersAndMarkdownFilesOnly() async throws {
        let store = VaultFileStore(rootURL: tempDirectory)
        try await store.write("---\n{}\n---\n", to: "_heimdal/watchlist.md")
        try await store.write("ignored", to: "_heimdal/notes.txt")
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("_heimdal/sources"),
            withIntermediateDirectories: true
        )
        let entries = try await store.listEntries(in: "_heimdal")
        XCTAssertTrue(entries.contains { $0.name == "watchlist.md" && !$0.isDirectory })
        XCTAssertTrue(entries.contains { $0.name == "sources" && $0.isDirectory })
        XCTAssertFalse(entries.contains { $0.name == "notes.txt" })
    }

    func testWritesUseCoordinatedAccess() async throws {
        let coordinator = RecordingCoordinator()
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)

        try await store.write("---\nvalue: initial\n---\n", to: "notes/example.md")
        _ = try await store.read("notes/example.md")
        let many = await store.readMany(["notes/example.md"])
        try await store.readModifyWrite("notes/example.md") { document in
            document.frontmatter["value"] = .string("updated")
        }
        _ = try await store.listEntries(in: "notes")

        XCTAssertEqual(coordinator.operations, [.write, .read, .read, .read, .write, .read])
        XCTAssertNotNil(try many["notes/example.md"]?.get())
    }

    func testStaleWriteIsReappliedOnFreshContent() async throws {
        let coordinator = RecordingCoordinator()
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)
        let path = "_heimdal/settings.md"
        try await store.write("---\nbase: true\n---\n", to: path)
        coordinator.operations = []
        coordinator.beforeNextWrite = { url in
            try "---\nbase: true\nmac: fresh\n---\n".write(to: url, atomically: true, encoding: .utf8)
        }

        try await store.readModifyWrite(path) { document in
            document.frontmatter["phone"] = .string("applied")
        }

        let text = try await store.read(path)
        XCTAssertTrue(text.contains("mac: fresh"))
        XCTAssertTrue(text.contains("phone: applied"))
        XCTAssertEqual(coordinator.operations, [.read, .write, .read, .write, .read])
    }

    func testDefaultAtomicWriterReplacesWholeFilesWithoutTempArtifacts() async throws {
        let path = "notes/atomic.md"
        let directory = tempDirectory.appendingPathComponent("notes")
        let oldText = "---\nversion: old\n---\n\n" + String(repeating: "old-content\n", count: 10_000)
        let newText = "---\nversion: new\n---\n\n" + String(repeating: "new-content\n", count: 10_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try oldText.write(to: directory.appendingPathComponent("atomic.md"), atomically: true, encoding: .utf8)

        let store = VaultFileStore(rootURL: tempDirectory)
        try await store.write(newText, to: path)

        let replaced = try String(contentsOf: directory.appendingPathComponent("atomic.md"), encoding: .utf8)
        XCTAssertTrue([oldText, newText].contains(replaced))
        XCTAssertEqual(replaced, newText)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["atomic.md"])

        try await store.readModifyWrite(path) { document in
            document.frontmatter["replaced"] = .bool(true)
        }
        let rendered = try await store.read(path)
        XCTAssertTrue(rendered.contains("replaced: true"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["atomic.md"])
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
        _ = try await assertRunsOffMain(modifyCoordinator) {
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
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let started = expectation(description: "background coordination started")
        coordinator.onAccessStarted = { started.fulfill() }
        let task = Task { try await operation() }
        await fulfillment(of: [started], timeout: 1)

        let mainActorTurn = Task { @MainActor in true }
        let mainActorAdvanced = await mainActorTurn.value
        XCTAssertTrue(mainActorAdvanced)
        let value = try await task.value
        XCTAssertFalse(coordinator.ranOnMainThread)
        return value
    }
}
