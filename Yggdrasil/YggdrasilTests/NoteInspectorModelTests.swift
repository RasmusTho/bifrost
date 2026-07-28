import XCTest
import YggdrasilCore
@testable import Yggdrasil

final class NoteInspectorModelTests: XCTestCase {
    func testInspectorFieldsFromFrontmatterAndMissingUuid() throws {
        let inspected = NoteInspectorModel(
            text: """
            ---
            uuid: note-123
            zone: Projects
            origin: human
            agent_provenance:
              author: bifrost-ios
              trace: test-trace
            ---

            # A note
            """,
            modificationDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(inspected.uuid, "note-123")
        XCTAssertEqual(inspected.zone, "Projects")
        XCTAssertEqual(inspected.origin, "human")
        XCTAssertEqual(inspected.agentProvenance["author"], "bifrost-ios")
        XCTAssertEqual(inspected.agentProvenance["trace"], "test-trace")
        XCTAssertNotNil(inspected.modifiedDescription)

        let missingUUID = NoteInspectorModel(text: "# Plain note", modificationDate: nil)
        XCTAssertNil(missingUUID.uuid)
        XCTAssertEqual(missingUUID.uuidDescription, "No uuid present")
    }

    func testCandidateResolutionIncludingMissingNotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimerEntityCandidateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let existingPath = MimerEntityCandidateResolver.registerPath(for: "ent:anna")
        let existingURL = root.appendingPathComponent(existingPath)
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        entity_id: ent:anna
        label: Anna Andersson
        kind: person
        lifecycle: canonical
        ---

        # Anna Andersson

        Existing canonical context.
        """.write(to: existingURL, atomically: true, encoding: .utf8)

        let candidates = await MimerEntityCandidateResolver.resolve(
            ["ent:anna", "ent:missing"],
            using: VaultFileStore(rootURL: root)
        )

        XCTAssertEqual(candidates.map(\.entityID), ["ent:anna", "ent:missing"])
        XCTAssertEqual(candidates[0].relativePath, "_heimdal/register/ent-anna.md")
        XCTAssertEqual(candidates[0].label, "Anna Andersson")
        XCTAssertEqual(candidates[0].kind, "person")
        XCTAssertEqual(candidates[0].lifecycle, "canonical")
        XCTAssertEqual(candidates[0].availability, .note)
        XCTAssertTrue(candidates[0].markdown.contains("Existing canonical context."))

        XCTAssertEqual(candidates[1].relativePath, "_heimdal/register/ent-missing.md")
        XCTAssertEqual(candidates[1].label, "ent:missing")
        XCTAssertEqual(candidates[1].availability, .missing)
        XCTAssertEqual(candidates[1].markdown, "")
    }
}
