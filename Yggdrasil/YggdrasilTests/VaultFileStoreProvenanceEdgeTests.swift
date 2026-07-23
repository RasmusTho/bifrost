import XCTest
@testable import Yggdrasil

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

extension VaultFileStoreTests {
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

    func testParserDisagreementAndInvalidYAMLPreserveRequestedBytes() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            "---\n{agent_provenance: old\n---\n\nBody.\n",
            "---\nagent_provenance: first\nagent_provenance: second\n---\n",
            "---\nbase: &ap agent_provenance\n*ap: stale\n---\n"
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
