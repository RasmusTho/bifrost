import XCTest
@testable import YggdrasilCore

private let fullYAMLSemanticCases = [
            (
                """
                ---
                "agent_\\u0070rovenance": stale
                title: Keep
                ---

                Body.
                """,
                """
                ---
                "former_writer_attribution": stale
                title: Keep
                ---

                Body.
                """
            ),
            (
                """
                ---
                base: &ap agent_provenance
                ? *ap
                : stale
                ---
                """,
                """
                ---
                base: &ap agent_provenance
                ? former_writer_attribution
                : stale
                ---
                """
            ),
            (
                """
                ---
                !local:writer agent_provenance: stale
                title: Keep
                ---
                """,
                """
                ---
                !local:writer former_writer_attribution: stale
                title: Keep
                ---
                """
            ),
            (
                """
                ---
                defaults: &defaults
                  agent_provenance: stale
                  foreign: keep
                <<: *defaults
                title: Keep
                ---
                """,
                """
                ---
                defaults: &defaults
                  former_writer_attribution: stale
                  foreign: keep
                <<: *defaults
                title: Keep
                ---
                """
            ),
            (
                """
                ---
                source: &source
                  agent_provenance: stale
                  foreign: keep
                <<: *source
                ---
                """,
                """
                ---
                source: &source
                  former_writer_attribution: stale
                  foreign: keep
                <<: *source
                ---
                """
            ),
            (
                """
                ---
                first: &first {agent_provenance: first}
                second: &second {agent_provenance: second}
                <<: [*first, *second]
                ---
                """,
                """
                ---
                first: &first {former_writer_attribution: first}
                second: &second {former_writer_attribution_2: second}
                <<: [*first, *second]
                ---
                """
            ),
            (
                """
                ---
                ? "agent_\\
                  provenance"
                : stale
                next: Keep
                ---
                """,
                """
                ---
                ? "former_writer_attribution"
                : stale
                next: Keep
                ---
                """
            ),
            (
                """
                ---
                "former_\\u0077riter_attribution": human
                "agent_\\u0070rovenance": stale
                ---
                """,
                """
                ---
                "former_\\u0077riter_attribution": human
                "former_writer_attribution_2": stale
                ---
                """
            ),
            (
                """
                ---
                name: &ap agent_provenance
                source: &source
                  ? *ap
                  : stale
                <<: *source
                ---
                """,
                """
                ---
                name: &ap agent_provenance
                source: &source
                  ? former_writer_attribution
                  : stale
                <<: *source
                ---
                """
            ),
            (
                """
                ---
                name: &ap agent_provenance
                source: &source
                  ? *ap
                  : stale
                  foreign: keep
                  other: keep
                <<: *source
                ---
                """,
                """
                ---
                name: &ap agent_provenance
                source: &source
                  ? former_writer_attribution
                  : stale
                  foreign: keep
                  other: keep
                <<: *source
                ---
                """
            ),
            (
                """
                ---
                foreign: {keep: value}
                name: &ap agent_provenance
                source: &source
                  ? *ap
                  : stale
                <<: *source
                ---
                """,
                """
                ---
                foreign: {keep: value}
                name: &ap agent_provenance
                source: &source
                  ? former_writer_attribution
                  : stale
                <<: *source
                ---
                """
            ),
            (
                """
                ---
                base: &base {agent_provenance: merged}
                <<: *base
                agent_provenance: direct
                ---
                """,
                """
                ---
                base: &base {former_writer_attribution_2: merged}
                <<: *base
                former_writer_attribution: direct
                ---
                """
            ),
            (
                """
                ---
                emoji: "🧭"
                "agent_\\u0070rovenance": stale
                ---
                """,
                """
                ---
                emoji: "🧭"
                "former_writer_attribution": stale
                ---
                """
            ),
            (
                """
                ---
                ? |-
                  agent_provenance
                : stale
                ---
                """,
                """
                ---
                ? former_writer_attribution
                : stale
                ---
                """
            ),
            (
                """
                ---
                ? >-
                  agent_provenance
                : stale
                ---
                """,
                """
                ---
                ? former_writer_attribution
                : stale
                ---
                """
            )
]

final class YAMLProvenanceTransformerTests: XCTestCase {
    func testFullYAMLSemanticsNeutralizeOnlyEffectiveProvenanceKey() {
        for (input, expected) in fullYAMLSemanticCases {
            let result = YAMLProvenanceTransformer.sanitizingFallback(input)
            XCTAssertEqual(result.outcome, .neutralizedStaleAttribution, input)
            XCTAssertEqual(result.text, expected, input)
        }

        assertFlowMappingInsertions()
        assertBlockMappingInsertions()
    }

    private func assertFlowMappingInsertions() {
        let timestamp = "2026-07-23T16:05:00Z"
        let insertionCases = [
            (
                "---\n{}\n---\n",
                "---\n{agent_provenance: {author: bifrost-ios, "
                    + "written_at: \(timestamp), origin: direct-fs}}\n---\n"
            ),
            (
                "---\n{tags: [one, two]}\n---\n",
                "---\n{tags: [one, two], agent_provenance: {author: bifrost-ios, "
                    + "written_at: \(timestamp), origin: direct-fs}}\n---\n"
            ),
            (
                "---\n{title: Keep, former_writer_attribution: {author: prior, trace: keep}}\n---\n",
                "---\n{title: Keep, former_writer_attribution: {author: prior, trace: keep}, "
                    + "agent_provenance: {author: bifrost-ios, written_at: \(timestamp), "
                    + "origin: direct-fs}}\n---\n"
            ),
            (
                "---\n!!map {title: Keep,}\n---\n",
                "---\n!!map {title: Keep, agent_provenance: {author: bifrost-ios, "
                    + "written_at: \(timestamp), origin: direct-fs}}\n---\n"
            ),
            (
                "---\n{title: Keep # retain comment\n}\n---\n",
                "---\n{title: Keep # retain comment\n, agent_provenance: "
                    + "{author: bifrost-ios, written_at: \(timestamp), "
                    + "origin: direct-fs}}\n---\n"
            ),
            (
                "---\n{title: Keep, # retain trailing-comma comment\n}\n---\n",
                "---\n{title: Keep, # retain trailing-comma comment\n "
                    + "agent_provenance: {author: bifrost-ios, written_at: \(timestamp), "
                    + "origin: direct-fs}}\n---\n"
            )
        ]
        assertInsertions(insertionCases, timestamp: timestamp)
    }

    private func assertBlockMappingInsertions() {
        let timestamp = "2026-07-23T16:05:00Z"
        let insertionCases = [
            (
                "---\n!!map\n  title: Keep\n---\n",
                "---\n!!map\n  title: Keep\n  agent_provenance:\n"
                    + "    author: bifrost-ios\n    written_at: \(timestamp)\n"
                    + "    origin: direct-fs\n---\n"
            ),
            (
                "---\r\ntitle: Keep\r\n---\r\n",
                "---\r\ntitle: Keep\r\nagent_provenance:\r\n"
                    + "  author: bifrost-ios\r\n  written_at: \(timestamp)\r\n"
                    + "  origin: direct-fs\r\n---\r\n"
            ),
            (
                "---\n!!map\n---\n",
                "---\n!!map\n  agent_provenance:\n"
                    + "    author: bifrost-ios\n    written_at: \(timestamp)\n"
                    + "    origin: direct-fs\n---\n"
            )
        ]
        assertInsertions(insertionCases, timestamp: timestamp)
    }

    private func assertInsertions(
        _ insertionCases: [(String, String)],
        timestamp: String
    ) {
        for (input, expected) in insertionCases {
            let inserted = YAMLProvenanceTransformer.insertingProvenance(
                into: input,
                writtenAt: timestamp
            )
            XCTAssertEqual(inserted, expected, input)
            XCTAssertEqual(
                inserted.map(YAMLProvenanceTransformer.sanitizingFallback)?.outcome,
                .neutralizedStaleAttribution,
                input
            )
        }
    }

    func testUnverifiableYAMLPreservesEveryByte() {
        let cases = [
            "---\n{agent_provenance: old\n---\n\nBody.\n",
            "---\nagent_provenance: first\nagent_provenance: second\n---\n",
            "---\nbase: &ap agent_provenance\n*ap: stale\n---\n",
            "---\r\n!local:writer \"agent_\\u0070rovenance\": stale\r\n"
                + "broken: [one, two\r\n---\r\nBody\r\n"
        ]

        for input in cases {
            let result = YAMLProvenanceTransformer.sanitizingFallback(input)
            XCTAssertEqual(result.outcome, .unverifiable, input)
            XCTAssertEqual(result.text, input, input)
        }
    }

    func testValidYAMLWithoutActiveProvenanceIsUnchanged() {
        let input = "---\ntitle: Keep\nnested:\n  agent_provenance: foreign\n---\n"
        let result = YAMLProvenanceTransformer.sanitizingFallback(input)

        XCTAssertEqual(result.outcome, .unchangedNoActiveProvenance)
        XCTAssertEqual(result.text, input)
    }
}
