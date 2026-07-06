import XCTest
@testable import Yggdrasil

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
}
