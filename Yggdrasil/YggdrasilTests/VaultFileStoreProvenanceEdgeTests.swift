import XCTest
@testable import Yggdrasil
import YggdrasilCore

private struct MergeSequenceBudgetCase {
    let path: String
    let input: String
    let expected: String
}
private let productionYAMLCases = [
            (
                "notes/escaped-key.md",
                """
                ---
                "agent_\\u0070rovenance": stale
                title: Keep
                ---
                """,
                """
                ---
                "former_writer_attribution": stale
                title: Keep
                ---
                """
            ),
            (
                "notes/explicit-alias-key.md",
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
                "notes/colon-tag.md",
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
                "notes/merge-projection.md",
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
                "notes/line-continuation.md",
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
            )
]

private let provenanceFailClosedCases = [
    ("notes/sequence-mapping.md", "---\n-\tauthor: human\n  note: keep\n---\n\nBody.\n"),
    ("notes/double-quoted.md", "---\n\"literal: scalar\"\n---\n\nBody.\n"),
    ("notes/single-quoted.md", "---\n'literal: scalar'\n---\n\nBody.\n"),
    ("notes/shared-anchor.md", "---\n? &ap agent_provenance\n: stale\nforeign: *ap\n---\n"),
    (
        "notes/invalid-scalar-merge.md",
        "---\n<<: 1\nagent_provenance: stale\ntitle: keep\n---\n"
    ),
    (
        "notes/invalid-null-merge.md",
        "---\n<<: null\nagent_provenance: stale\ntitle: keep\n---\n"
    ),
    (
        "notes/invalid-mixed-merge.md",
        "---\nbase: &base {foreign: keep}\n<<: [*base, 1]\n"
            + "agent_provenance: stale\n---\n"
    ),
    (
        "notes/inline-flow-merge-shared-anchor.md",
        "---\n<<: &base {agent_provenance: stale, keep: yes}\n"
            + "foreign: *base\n---\n"
    ),
    (
        "notes/inline-block-merge-shared-anchor.md",
        "---\n<<: &base\n  agent_provenance: stale\n  keep: yes\n"
            + "foreign: *base\n---\n"
    ),
    (
        "notes/set-with-provenance-name.md",
        "---\n!!set\n? agent_provenance\n? foreign\n---\n"
    ),
    ("notes/set-without-provenance-name.md", "---\n!!set\n? foreign\n---\n")
]

extension VaultFileStoreTests {
    func testFullYAMLMappingsAreTaggedAndNonMappingsFailClosed() async throws {
        let timestamp = "2026-07-21T10:30:00Z"
        let taggedCases = [
            (
                "notes/empty-map.md",
                "---\n{}\n---\n\nBody.\n",
                "---\n{agent_provenance: {author: bifrost-ios, written_at: \(timestamp), "
                    + "origin: direct-fs}}\n---\n\nBody.\n"
            ),
            (
                "notes/flow-map.md",
                "---\n{tags: [one, two]}\n---\n\nBody.\n",
                "---\n{tags: [one, two], agent_provenance: {author: bifrost-ios, "
                    + "written_at: \(timestamp), origin: direct-fs}}\n---\n\nBody.\n"
            ),
            (
                "notes/tagged-empty-map.md",
                "---\n!!map\n---\n\nBody.\n",
                "---\n!!map\n  agent_provenance:\n    author: bifrost-ios\n"
                    + "    written_at: \(timestamp)\n    origin: direct-fs\n---\n\nBody.\n"
            )
        ]
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp }
        )

        for (path, text, expected) in taggedCases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected)
            XCTAssertEqual(
                YAMLProvenanceTransformer.sanitizingFallback(saved).outcome,
                .neutralizedStaleAttribution
            )
        }
    }

    func testNonMappingsAndUnverifiableMappingsFailClosed() async throws {
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { "2026-07-21T10:30:00Z" },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, text) in provenanceFailClosedCases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
        }
        XCTAssertEqual(loggedFailures.values.count, provenanceFailClosedCases.count)
    }

    func testGenericWriteInsertsFreshProvenanceWithoutChangingForeignYAML() async throws {
        let path = "notes/fresh-provenance.md"
        let timestamp = "2026-07-23T15:47:00Z"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        let input = """
        ---
        title: Keep
        tags:
          - one
          - two
        nested:
          owner: human
        description: |
          first line
          second line
        ---

        Body.
        """

        try await store.write(input, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, """
        ---
        title: Keep
        tags:
          - one
          - two
        nested:
          owner: human
        description: |
          first line
          second line
        agent_provenance:
          author: bifrost-ios
          written_at: \(timestamp)
          origin: direct-fs
        ---

        Body.
        """)
        XCTAssertEqual(
            YAMLProvenanceTransformer.sanitizingFallback(saved).outcome,
            .neutralizedStaleAttribution
        )
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }

    func testFullYAMLRefreshRetainsPriorWriterAndInsertsCurrentProvenance() async throws {
        let path = "notes/flow-refresh.md"
        let timestamp = "2026-07-23T16:05:00Z"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        let input = "---\n{title: Keep, agent_provenance: {author: prior, trace: keep}}\n---\n"
        let expected = "---\n{title: Keep, former_writer_attribution: {author: prior, trace: keep}, "
            + "agent_provenance: {author: bifrost-ios, written_at: \(timestamp), origin: direct-fs}}\n---\n"

        try await store.write(input, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(
            YAMLProvenanceTransformer.sanitizingFallback(saved).outcome,
            .neutralizedStaleAttribution
        )
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }

    func testCRLFFoldedKeyCommentSurvivesProvenanceRefresh() async throws {
        let timestamp = "2026-07-21T10:30:00Z"
        let path = "notes/crlf-folded-key.md"
        let input = "---\r\n? >- # retain CRLF folded comment\r\n"
            + "  agent_provenance\r\n: {author: old, trace: keep}\r\n---\r\n"
        let expected = "---\r\n? >- # retain CRLF folded comment\r\n"
            + "  former_writer_attribution\r\n: {author: old, trace: keep}\r\n"
            + "agent_provenance:\r\n  author: bifrost-ios\r\n"
            + "  written_at: \(timestamp)\r\n  origin: direct-fs\r\n---\r\n"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        try await store.write(input, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, expected)
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }

    func testProductionYAMLSemanticsDriveLosslessFallback() async throws {
        struct ProvenanceFailure: Error {}
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, input, expected) in productionYAMLCases {
            try await store.write(input, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected, path)
        }

        XCTAssertEqual(loggedFailures.values.count, productionYAMLCases.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy {
            $0.contains("neutralized stale attribution before writing sanitized bytes")
        })
    }

    func testMergeSequenceNeutralizesEveryProjectedPrecedenceLayer() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/merge-sequence.md"
        let input = """
        ---
        first: &first {agent_provenance: first}
        second: &second {agent_provenance: second}
        <<: [*first, *second]
        ---
        """
        let expected = """
        ---
        first: &first {former_writer_attribution: first}
        second: &second {former_writer_attribution_2: second}
        <<: [*first, *second]
        ---
        """
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() }
        )

        try await store.write(input, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, expected)
    }

    func testMergeSequenceBudgetCoversEveryConcreteSource() async throws {
        let timestamp = "2026-07-23T19:40:00Z"
        let cases = [
            flowMergeSequenceBudgetCase(timestamp: timestamp),
            blockMergeSequenceBudgetCase(timestamp: timestamp)
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for testCase in cases {
            try await store.write(testCase.input, to: testCase.path)
            let saved = try await store.read(testCase.path)
            XCTAssertEqual(saved, testCase.expected, testCase.path)
        }
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }
    private func flowMergeSequenceBudgetCase(timestamp: String) -> MergeSequenceBudgetCase {
        MergeSequenceBudgetCase(
            path: "notes/flow-merge-sequence-edit-budget.md",
            input: """
            ---
            <<:
              - &one {agent_provenance: one}
              - &two {agent_provenance: two}
              - &three {agent_provenance: three}
              - &four {agent_provenance: four}
              - *one
              - *two
              - *three
              - *four
            ---
            """,
            expected: """
            ---
            <<:
              - &one {former_writer_attribution: one}
              - &two {former_writer_attribution_2: two}
              - &three {former_writer_attribution_3: three}
              - &four {former_writer_attribution_4: four}
              - *one
              - *two
              - *three
              - *four
            agent_provenance:
              author: bifrost-ios
              written_at: \(timestamp)
              origin: direct-fs
            ---
            """
        )
    }
    private func blockMergeSequenceBudgetCase(timestamp: String) -> MergeSequenceBudgetCase {
        MergeSequenceBudgetCase(
            path: "notes/block-merge-sequence-edit-budget.md",
            input: """
            ---
            <<:
              - &one
                agent_provenance: one
              - &two
                agent_provenance: two
              - &three
                agent_provenance: three
              - &four
                agent_provenance: four
              - *one
              - *two
              - *three
              - *four
            ---
            """,
            expected: """
            ---
            <<:
              - &one
                former_writer_attribution: one
              - &two
                former_writer_attribution_2: two
              - &three
                former_writer_attribution_3: three
              - &four
                former_writer_attribution_4: four
              - *one
              - *two
              - *three
              - *four
            agent_provenance:
              author: bifrost-ios
              written_at: \(timestamp)
              origin: direct-fs
            ---
            """
        )
    }
    func testParserDisagreementAndInvalidYAMLPreserveRequestedBytes() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            "---\n{agent_provenance: old\n---\n\nBody.\n",
            "---\nagent_provenance: first\nagent_provenance: second\n---\n",
            "---\nbase: &ap agent_provenance\n*ap: stale\n---\n",
            "---\n? &ap agent_provenance\n: stale\nforeign: *ap\n---\n",
            "---\n<<: 1\nagent_provenance: stale\ntitle: keep\n---\n",
            "---\n<<: null\nagent_provenance: stale\ntitle: keep\n---\n",
            "---\nbase: &base {foreign: keep}\n<<: [*base, 1]\n"
                + "agent_provenance: stale\n---\n",
            "---\n<<: &base {agent_provenance: stale, keep: yes}\n"
                + "foreign: *base\n---\n",
            "---\n<<: &base\n  agent_provenance: stale\n  keep: yes\n"
                + "foreign: *base\n---\n",
            "---\n!!set\n? agent_provenance\n? foreign\n---\n",
            "---\n!!set\n? foreign\n---\n"
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (index, input) in cases.enumerated() {
            let path = "notes/unverifiable-\(index).md"
            try await store.write(input, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, input)
        }

        XCTAssertEqual(loggedFailures.values.count, cases.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy {
            $0.contains("writing requested bytes without refreshed provenance")
        })
    }

    func testSemanticNeutralKeyCollisionAllocatesDistinctKey() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/semantic-neutral-collision.md"
        let input = """
        ---
        "former_\\u0077riter_attribution": human
        "agent_\\u0070rovenance": stale
        ---
        """
        let expected = """
        ---
        "former_\\u0077riter_attribution": human
        "former_writer_attribution_2": stale
        ---
        """
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() }
        )

        try await store.write(input, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, expected)
    }
}
