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
            )
]

final class YAMLProvenanceTransformerTests: XCTestCase {
    func testFullYAMLSemanticsNeutralizeOnlyEffectiveProvenanceKey() {
        for (input, expected) in fullYAMLSemanticCases {
            let result = YAMLProvenanceTransformer.sanitizingFallback(input)
            XCTAssertEqual(result.outcome, .neutralizedStaleAttribution, input)
            XCTAssertEqual(result.text, expected, input)
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
