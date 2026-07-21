import XCTest
@testable import Yggdrasil

extension VaultFileStoreTests {
    func testJSONCompatibleFlowKeysNeutralizeWithoutChangingValues() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            "{\"agent_provenance\":\"old\",\"title\":\"Keep\"}",
            "{'agent_provenance':'old','title':'Keep'}",
            "{\"agent_provenance\":! \"old\",\"title\":\"Keep\"}",
            "{!<tag:agent_provenance> \"agent_provenance\": old, title: Keep}"
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (index, frontmatter) in cases.enumerated() {
            let path = "notes/json-flow-\(index).md"
            let text = "---\n\(frontmatter)\n---\n\nBody.\n"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            let keyOccurrence = frontmatter.range(of: "agent_provenance", options: .backwards)
            let expectedFrontmatter = keyOccurrence.map {
                frontmatter.replacingCharacters(in: $0, with: "former_writer_attribution")
            }
            XCTAssertEqual(saved, "---\n\(expectedFrontmatter ?? frontmatter)\n---\n\nBody.\n")
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy { $0.contains("neutralized stale attribution") })
    }

    func testMultilineExplicitRootKeyNeutralizesOnlyTheKeyToken() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            (
                "notes/multiline-explicit-provenance-key.md",
                "---\n?\n  !<tag:agent_provenance> \"agent_provenance\"\n"
                    + ": {author: another-writer}\nnext: Keep\n---\n\nBody.\n",
                "---\n?\n  !<tag:agent_provenance> \"former_writer_attribution\"\n"
                    + ": {author: another-writer}\nnext: Keep\n---\n\nBody.\n"
            ),
            (
                "notes/multiline-property-lines.md",
                "---\n?\n  !!str\n  &key\n  agent_provenance # key comment\n"
                    + ": {author: another-writer}\nnext: Keep\n---\n\nBody.\n",
                "---\n?\n  !!str\n  &key\n  former_writer_attribution # key comment\n"
                    + ": {author: another-writer}\nnext: Keep\n---\n\nBody.\n"
            )
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, text, expected) in cases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy { $0.contains("neutralized stale attribution") })
    }

    func testAliasResolvedRootKeysAreNeutralizedLosslessly() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            (
                "notes/alias-flow-root.md",
                "---\n{base: &ap agent_provenance, *ap: {author: old}, title: Keep}\n---\n",
                "---\n{base: &ap agent_provenance, former_writer_attribution: {author: old}, title: Keep}\n---\n"
            ),
            (
                "notes/alias-block-root.md",
                "---\nbase: &ap agent_provenance\n*ap: {author: old}\ntitle: Keep\n---\n",
                "---\nbase: &ap agent_provenance\nformer_writer_attribution: {author: old}\ntitle: Keep\n---\n"
            ),
            (
                "notes/mixed-alias-root.md",
                "---\nbase: &ap agent_provenance\nagent_provenance: literal\n*ap: alias\n---\n",
                "---\nbase: &ap agent_provenance\nformer_writer_attribution: literal\n"
                    + "former_writer_attribution_2: alias\n---\n"
            )
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, text, expected) in cases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy { $0.contains("neutralized stale attribution") })
    }

    func testCommentedExplicitFlowKeyNeutralizesOnlyTheKeyToken() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/commented-explicit-flow-key.md"
        let text = "---\n{? agent_provenance # key comment\n : {author: old}, next: Keep}\n---\n"
        let expected = "---\n{? former_writer_attribution # key comment\n : {author: old}, next: Keep}\n---\n"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        try await store.write(text, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains("neutralized stale attribution"))
    }

    func testAliasUsesLatestAnchorBindingBeforeTheKey() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/redefined-alias-key.md"
        let text = "---\nactive: &ap agent_provenance\nforeign: &ap human-key\n*ap: keep\n---\n"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        try await store.write(text, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, text)
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains("without refreshed provenance"))
    }

    func testTextualNeutralKeyCollisionsAllocateSuffixes() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            (
                "notes/neutral-collision-block.md",
                "---\nformer_writer_attribution: human\nagent_provenance: stale\n---\n",
                "---\nformer_writer_attribution: human\nformer_writer_attribution_2: stale\n---\n"
            ),
            (
                "notes/neutral-collision-flow.md",
                "---\n{former_writer_attribution: human, agent_provenance: stale}\n---\n",
                "---\n{former_writer_attribution: human, former_writer_attribution_2: stale}\n---\n"
            )
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, text, expected) in cases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testComplexNullAndPlainTextAnchorsDoNotAuthorizeAliasRenames() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            "---\nbase: &ap\n  agent_provenance: nested\n*ap: value\n---\n",
            "---\nbase: &ap\nagent_provenance: stale\n*ap: value\n---\n",
            "---\nreal: &ap human-key\ntext: hello &ap agent_provenance\n*ap: foreign\n---\n",
            "---\nreal: &ap human-key\ntext: |\n  field: &ap agent_provenance\n*ap: foreign\n---\n"
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (index, text) in cases.enumerated() {
            let path = "notes/non-scalar-anchor-\(index).md"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            let expected = index == 1
                ? text.replacingOccurrences(of: "agent_provenance", with: "former_writer_attribution")
                : text
            XCTAssertEqual(saved, expected)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testExplicitKeyReplacementNeverChangesRepeatedCommentText() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            (
                "notes/repeated-literal-comment.md",
                "---\n? agent_provenance # mention agent_provenance\n: old\n---\n",
                "---\n? former_writer_attribution # mention agent_provenance\n: old\n---\n"
            ),
            (
                "notes/repeated-alias-comment.md",
                "---\nbase: &ap agent_provenance\n? *ap # mention *ap\n: old\n---\n",
                "---\nbase: &ap agent_provenance\n? former_writer_attribution # mention *ap\n: old\n---\n"
            ),
            (
                "notes/repeated-flow-comment.md",
                "---\n{? agent_provenance # mention agent_provenance\n : old, next: Keep}\n---\n",
                "---\n{? former_writer_attribution # mention agent_provenance\n : old, next: Keep}\n---\n"
            )
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, text, expected) in cases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testAnchorProofRequiresTheCompleteScalarValue() async throws {
        struct ProvenanceFailure: Error {}
        let lookalikes = [
            "agent_provenance extra",
            "agent_provenance:foo",
            "agent_provenance[foo]",
            "agent_provenance,foo"
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (index, lookalike) in lookalikes.enumerated() {
            let path = "notes/anchor-lookalike-\(index).md"
            let text = "---\nbase: &ap \(lookalike)\n*ap: foreign\n---\n"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
        }
        XCTAssertEqual(loggedFailures.values.count, lookalikes.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy { $0.contains("without refreshed provenance") })
    }

    func testNonScalarAnchorRedefinitionsClearPriorActiveBindings() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            "---\nactive: &ap agent_provenance\nforeign: &ap\n  nested: value\n*ap: keep\n---\n",
            "---\nactive: &ap agent_provenance\nforeign: &ap\n*ap: keep\n---\n"
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (index, text) in cases.enumerated() {
            let path = "notes/inactive-anchor-redefinition-\(index).md"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testMultilinePlainScalarCannotForgeAnAnchorBinding() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/multiline-plain-anchor-lookalike.md"
        let text = "---\nreal: &ap human-key\ntext: hello\n  &ap agent_provenance\n*ap: foreign\n---\n"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        try await store.write(text, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, text)
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains("without refreshed provenance"))
    }

    func testCommentColonsCannotTurnScalarDocumentsIntoMappings() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            "---\nagent_provenance # mention: value\n---\n",
            "---\n\"agent_provenance\" # mention: value\n---\n"
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (index, text) in cases.enumerated() {
            let path = "notes/comment-colon-scalar-\(index).md"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }
}
