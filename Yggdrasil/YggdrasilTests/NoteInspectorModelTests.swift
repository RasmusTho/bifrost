import XCTest
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
}
