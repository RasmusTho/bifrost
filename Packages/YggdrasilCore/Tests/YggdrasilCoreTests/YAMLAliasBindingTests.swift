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

    func testTransitiveMergeWrapperWithoutForeignConsumerRefreshes() {
        assertRefresh(
            """
            ---
            base: &base {agent_provenance: stale, keep: base}
            wrapper: &wrapper {<<: *base, keep: wrapper}
            <<: *wrapper
            ---
            """,
            expected: """
            ---
            base: &base {former_writer_attribution: stale, keep: base}
            wrapper: &wrapper {<<: *base, keep: wrapper}
            <<: *wrapper
            agent_provenance:
              author: bifrost-ios
              written_at: 2026-07-23T21:20:00Z
              origin: direct-fs
            ---
            """
        )
    }

    func testTransitiveMergeWrapperWithForeignConsumerFailsClosed() {
        let cases = [
            """
            ---
            base: &base {agent_provenance: stale, keep: base}
            wrapper: &wrapper {<<: *base, keep: wrapper}
            <<: *wrapper
            foreign: *wrapper
            ---
            """,
            """
            ---
            base: &base
              agent_provenance: stale
              keep: base
            wrapper: &wrapper
              <<: *base
              keep: wrapper
            outer: &outer
              <<: *wrapper
              keep: outer
            <<: *outer
            foreign: *outer
            ---
            """
        ]

        for input in cases {
            let result = YAMLProvenanceTransformer.sanitizingFallback(input)
            XCTAssertEqual(result.outcome, .unverifiable, input)
            XCTAssertEqual(result.text, input, input)
            XCTAssertNil(
                YAMLProvenanceTransformer.upsertingProvenance(
                    into: input,
                    writtenAt: "2026-07-24T06:40:00Z"
                ),
                input
            )
        }
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
