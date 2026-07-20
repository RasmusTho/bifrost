import XCTest
import YggdrasilCore
@testable import Yggdrasil

final class VaultFileStoreBasicTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YggdrasilVaultFileStoreBasicTests-\(UUID().uuidString)")
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
}
