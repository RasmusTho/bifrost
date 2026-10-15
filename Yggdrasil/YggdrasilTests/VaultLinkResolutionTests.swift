import XCTest
@testable import Yggdrasil

/// Obsidian-style link resolution for the note renderer (on demand, no index).
final class VaultLinkResolutionTests: XCTestCase {
    private let files = [
        "Projects/fixture.md",
        "Projects/source.md",
        "Archive/source.md",
        "Inbox/Idea.md",
        "Assets/diagram.png",
        "Projects/assets/diagram.png",
        "Docs/report.pdf",
        "Notes/Deep/Topic.md"
    ]

    private func resolve(_ target: String, from note: String = "Projects/fixture.md") -> VaultLinkResolution? {
        VaultFileStore.resolve([target], from: note, among: files)[target]
    }

    func testBareNameResolvesToTheMarkdownNote() {
        XCTAssertEqual(resolve("Idea"), VaultLinkResolution(path: "Inbox/Idea.md", kind: .note))
        XCTAssertEqual(resolve("idea"), VaultLinkResolution(path: "Inbox/Idea.md", kind: .note))
    }

    func testDuplicateNamesPreferTheLinkingNotesFolder() {
        XCTAssertEqual(resolve("source")?.path, "Projects/source.md")
        XCTAssertEqual(resolve("source", from: "Archive/x.md")?.path, "Archive/source.md")
        XCTAssertEqual(resolve("diagram.png")?.path, "Projects/assets/diagram.png")
    }

    func testPathQualifiedAndRelativeTargets() {
        XCTAssertEqual(resolve("Archive/source")?.path, "Archive/source.md")
        XCTAssertEqual(resolve("Deep/Topic")?.path, "Notes/Deep/Topic.md")
        XCTAssertEqual(resolve("assets/diagram.png")?.path, "Projects/assets/diagram.png")
    }

    func testAssetsAreClassifiedAsAssets() {
        XCTAssertEqual(resolve("report.pdf"), VaultLinkResolution(path: "Docs/report.pdf", kind: .asset))
    }

    func testMissingAndEscapingTargetsDoNotResolve() {
        XCTAssertNil(resolve("Nope"))
        XCTAssertNil(resolve("../secret"))
        XCTAssertFalse(VaultFileStore.isContained("../x.png"))
        XCTAssertFalse(VaultFileStore.isContained("a/./b"))
        XCTAssertFalse(VaultFileStore.isContained("/etc/passwd"))
        XCTAssertTrue(VaultFileStore.isContained("Assets/diagram.png"))
    }

    func testEnumerationSkipsHiddenAndObsidianFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkResolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["A/Note.md", ".obsidian/app.json", ".hidden.md", "B/img.png"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: url)
        }
        XCTAssertEqual(VaultFileStore.enumerateFiles(under: root).sorted(), ["A/Note.md", "B/img.png"])
    }
}
