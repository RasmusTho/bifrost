import XCTest
@testable import YggdrasilCore

final class YAMLAliasBindingTests: XCTestCase {
    func testFlowAnchorReuseBindsAliasesToNearestPriorDefinition() {
        assertRefresh(
            """
            ---
            first: &same {foreign: one}
            foreign_use: *same
            second: &same {agent_provenance: second}
            <<: *same
            ---
            """,
            expected: """
            ---
            first: &same {foreign: one}
            foreign_use: *same
            second: &same {former_writer_attribution: second}
            <<: *same
            agent_provenance:
              author: bifrost-ios
              written_at: 2026-07-23T21:20:00Z
              origin: direct-fs
            ---
            """
        )
    }

    func testBlockAnchorReuseBindsAliasesToNearestPriorDefinition() {
        assertRefresh(
            """
            ---
            first: &same
              foreign: one
            foreign_use: *same
            second: &same
              agent_provenance: second
            <<: *same
            ---
            """,
            expected: """
            ---
            first: &same
              foreign: one
            foreign_use: *same
            second: &same
              former_writer_attribution: second
            <<: *same
            agent_provenance:
              author: bifrost-ios
              written_at: 2026-07-23T21:20:00Z
              origin: direct-fs
            ---
            """
        )
    }

    private func assertRefresh(
        _ input: String,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            YAMLProvenanceTransformer.upsertingProvenance(
                into: input,
                writtenAt: "2026-07-23T21:20:00Z"
            ),
            expected,
            file: file,
            line: line
        )
    }
}
