import XCTest
import YggdrasilCore
@testable import Yggdrasil

private enum VaultFileStoreCoordinationOperation: Equatable {
    case read
    case write
}

final class VaultFileStoreTests: XCTestCase {
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

    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YggdrasilVaultFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testWriteThenReadRoundTrips() throws {
        let store = VaultFileStore(rootURL: tempDirectory)
        try store.write("---\nfoo: bar\n---\n\nBody.\n", to: "_heimdal/settings.md")
        let text = try store.read("_heimdal/settings.md")
        XCTAssertTrue(text.contains("foo: bar"))
    }

    func testReadModifyWriteCreatesNoteWhenMissing() throws {
        let store = VaultFileStore(rootURL: tempDirectory)
        try store.readModifyWrite("_heimdal/interests.md") { document in
            document.frontmatter["weights"] = .map({
                var map = YAMLMap()
                map["reading"] = .double(0.5)
                return map
            }())
        }
        let text = try store.read("_heimdal/interests.md")
        XCTAssertTrue(text.contains("weights:"))
        XCTAssertTrue(text.contains("reading: 0.5"))
    }

    func testListEntriesReturnsFoldersAndMarkdownFilesOnly() throws {
        let store = VaultFileStore(rootURL: tempDirectory)
        try store.write("---\n{}\n---\n", to: "_heimdal/watchlist.md")
        try store.write("ignored", to: "_heimdal/notes.txt")
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("_heimdal/sources"),
            withIntermediateDirectories: true
        )
        let entries = try store.listEntries(in: "_heimdal")
        XCTAssertTrue(entries.contains { $0.name == "watchlist.md" && !$0.isDirectory })
        XCTAssertTrue(entries.contains { $0.name == "sources" && $0.isDirectory })
        XCTAssertFalse(entries.contains { $0.name == "notes.txt" })
    }

    func testWritesUseCoordinatedAccess() throws {
        let coordinator = RecordingCoordinator()
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)

        try store.write("---\nvalue: initial\n---\n", to: "notes/example.md")
        _ = try store.read("notes/example.md")
        let many = store.readMany(["notes/example.md"])
        try store.readModifyWrite("notes/example.md") { document in
            document.frontmatter["value"] = .string("updated")
        }
        _ = try store.listEntries(in: "notes")

        XCTAssertEqual(coordinator.operations, [.write, .read, .read, .read, .write, .read])
        XCTAssertNotNil(try many["notes/example.md"]?.get())
    }

    func testStaleWriteIsReappliedOnFreshContent() throws {
        let coordinator = RecordingCoordinator()
        let store = VaultFileStore(rootURL: tempDirectory, coordinator: coordinator)
        let path = "_heimdal/settings.md"
        try store.write("---\nbase: true\n---\n", to: path)
        coordinator.operations = []
        coordinator.beforeNextWrite = { url in
            try "---\nbase: true\nmac: fresh\n---\n".write(to: url, atomically: true, encoding: .utf8)
        }

        try store.readModifyWrite(path) { document in
            document.frontmatter["phone"] = .string("applied")
        }

        let text = try store.read(path)
        XCTAssertTrue(text.contains("mac: fresh"))
        XCTAssertTrue(text.contains("phone: applied"))
        XCTAssertEqual(coordinator.operations, [.read, .write, .read, .write, .read])
    }

    func testWholeFileWriteIsAtomicReplace() throws {
        var atomicReplaceWasUsed = false
        let store = VaultFileStore(
            rootURL: tempDirectory,
            atomicWriter: { text, url in
                atomicReplaceWasUsed = true
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        )

        try store.write("complete replacement", to: "notes/atomic.md")

        XCTAssertTrue(atomicReplaceWasUsed)
        XCTAssertEqual(try store.read("notes/atomic.md"), "complete replacement")
    }
}
