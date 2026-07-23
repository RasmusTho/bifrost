import XCTest
@testable import Yggdrasil
import YggdrasilCore

extension VaultFileStoreTests {
    func testUnsupportedFrontmatterIsTaggedWithoutChangingForeignYAML() async throws {
        let path = "notes/human-yaml.md"
        let timestamp = "2026-07-21T10:30:00Z"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        let text = """
        ---
        tags: [one, two] # keep
        description: |
          first line
          second line
        anchor: &kept value
        alias: *kept
        agent_provenance:
          author: old-writer
          written_at: 2025-01-01T00:00:00Z
          origin: imported
          model: old-model
          trace: old-trace
        ---

        Body.
        """
        try await store.write(text, to: path)
        let saved = try await store.read(path)
        XCTAssertEqual(saved, """
        ---
        tags: [one, two] # keep
        description: |
          first line
          second line
        anchor: &kept value
        alias: *kept
        agent_provenance:
          author: bifrost-ios
          written_at: \(timestamp)
          origin: direct-fs
        ---

        Body.
        """)
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }
    func testAmbiguousExistingProvenanceIsNeutralizedAndLogged() async throws {
        let cases = [
            (
                "notes/block-provenance.md",
                "---\ntitle: Keep\nagent_provenance: |\n  legacy attribution\nnext: keep\n---\n\nBody.\n",
                "---\ntitle: Keep\nformer_writer_attribution: |\n  legacy attribution\nnext: keep\n---\n\nBody.\n"
            ),
            (
                "notes/separated-provenance.md",
                "---\ntitle: Keep\nagent_provenance:\n  author: old\n# human explanation\n\n"
                    + "  written_at: old\n  origin: imported\nnext: keep\n---\n\nBody.\n",
                "---\ntitle: Keep\nformer_writer_attribution:\n  author: old\n# human explanation\n\n"
                    + "  written_at: old\n  origin: imported\nnext: keep\n---\n\nBody.\n"
            ),
            (
                "notes/indentless-sequence.md",
                "---\nagent_provenance:\n- author: old\nnext: keep\n---\n",
                "---\nformer_writer_attribution:\n- author: old\nnext: keep\n---\n"
            )
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { "2026-07-21T10:30:00Z" },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        for (path, text, expected) in cases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected)
            XCTAssertFalse(saved.contains("agent_provenance"))
            XCTAssertTrue(saved.contains("former_writer_attribution"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        for (path, _, _) in cases {
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
        XCTAssertTrue(loggedFailures.values.allSatisfy {
            $0.contains("neutralized stale attribution before writing sanitized bytes")
        })
    }

    func testMultilineFlowProvenanceFailurePreservesForeignYAML() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/multiline-flow-provenance.md"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        let text = """
        ---
        title: Keep
        agent_provenance: {
          author: another-writer,
        # retain this human comment
          written_at: old,
          origin: imported,
          trace: "}, # still provenance"
        }
        tags: [one, two]
        ---

        Body.
        """
        try await store.write(text, to: path)
        let saved = try await store.read(path)
        XCTAssertEqual(saved, """
        ---
        title: Keep
        former_writer_attribution: {
          author: another-writer,
        # retain this human comment
          written_at: old,
          origin: imported,
          trace: "}, # still provenance"
        }
        tags: [one, two]
        ---

        Body.
        """)
        XCTAssertFalse(saved.contains("agent_provenance"))
        XCTAssertTrue(saved.contains("another-writer"))
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains("neutralized stale attribution"))
    }

    func testPlainScalarDelimitersDoNotConsumeForeignFields() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            ("notes/plain-curly.md", "old { writer"),
            ("notes/plain-square.md", "writer [legacy")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        for (path, staleValue) in cases {
            let text = "---\ntitle: Keep\nagent_provenance: \(staleValue)\n"
                + "next: preserve-me\n---\n\nBody.\n"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(
                saved,
                "---\ntitle: Keep\nformer_writer_attribution: \(staleValue)\n"
                    + "next: preserve-me\n---\n\nBody.\n"
            )
            XCTAssertFalse(saved.contains("agent_provenance"))
            XCTAssertTrue(saved.contains(staleValue))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        for (path, _) in cases {
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
    }

    func testIndentedRootProvenanceFailurePreservesNestedSameNameField() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/indented-root.md"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        let text = "---\n  title: Keep\n  nested:\n    agent_provenance: nested-human-data\n"
            + "  agent_provenance:\n    author: another-writer\n    written_at: old\n"
            + "  next: preserve-me\n---\n\nBody.\n"
        try await store.write(text, to: path)
        let saved = try await store.read(path)
        XCTAssertEqual(
            saved,
            "---\n  title: Keep\n  nested:\n    agent_provenance: nested-human-data\n"
                + "  former_writer_attribution:\n    author: another-writer\n    written_at: old\n"
                + "  next: preserve-me\n---\n\nBody.\n"
        )
        XCTAssertTrue(saved.contains("agent_provenance: nested-human-data"))
        XCTAssertTrue(saved.contains("another-writer"))
        XCTAssertEqual(loggedFailures.values.count, 1)
    }

    func testFlowRootProvenanceFailurePreservesForeignYAML() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/flow-root-provenance.md"
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        let text = """
        ---
        {title: "Keep # literal, { brace", # retain this human comment
         agent_provenance: {author: another-writer, written_at: old, trace: "}, # provenance"},
         tags: [one, two]}
        ---

        Body.
        """
        try await store.write(text, to: path)
        let saved = try await store.read(path)
        let expected = text.replacingOccurrences(
            of: "agent_provenance",
            with: "former_writer_attribution"
        )
        XCTAssertEqual(saved, expected)
        XCTAssertFalse(saved.contains("agent_provenance"))
        XCTAssertTrue(saved.contains("another-writer"))
        XCTAssertEqual(loggedFailures.values.count, 1)
    }

    func testFlowRootNodePropertiesPreserveForeignYAML() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            ("notes/anchored-flow-root.md", "&root"),
            ("notes/tagged-flow-root.md", "!!map")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        for (path, property) in cases {
            let text = "---\n\(property) {agent_provenance: {author: another-writer}, title: Keep}\n"
                + "---\n\nBody.\n"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(
                saved,
                "---\n\(property) {former_writer_attribution: {author: another-writer}, title: Keep}\n"
                    + "---\n\nBody.\n"
            )
            XCTAssertFalse(saved.contains("agent_provenance"))
            XCTAssertTrue(saved.contains("another-writer"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        for (path, _) in cases {
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
    }

    func testBlockRootNodePropertiesPreserveNestedSameNameField() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            ("notes/anchored-block-root.md", "&root"),
            ("notes/tagged-block-root.md", "!!map"),
            ("notes/tagged-anchored-block-root.md", "!!map &root")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        for (path, property) in cases {
            let text = "---\n\(property)\n  nested:\n    agent_provenance: nested-human-data\n"
                + "  agent_provenance:\n    author: another-writer\n  title: Keep\n---\n\nBody.\n"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            let expected = "---\n\(property)\n  nested:\n    agent_provenance: nested-human-data\n"
                + "  former_writer_attribution:\n    author: another-writer\n"
                + "  title: Keep\n---\n\nBody.\n"
            XCTAssertEqual(saved, expected)
            XCTAssertTrue(saved.contains("agent_provenance: nested-human-data"))
            XCTAssertTrue(saved.contains("another-writer"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        for (path, _) in cases {
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
    }

    func testNonSpecificTagRootsNeutralizeStaleProvenance() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            (
                "notes/non-specific-flow-root.md",
                "---\n! {agent_provenance: {author: another-writer}, title: Keep}\n---\n\nBody.\n",
                "---\n! {former_writer_attribution: {author: another-writer}, title: Keep}\n---\n\nBody.\n"
            ),
            (
                "notes/non-specific-block-root.md",
                "---\n!\n  agent_provenance:\n    author: another-writer\n  title: Keep\n---\n\nBody.\n",
                "---\n!\n  former_writer_attribution:\n    author: another-writer\n  title: Keep\n---\n\nBody.\n"
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
            XCTAssertTrue(saved.contains("another-writer"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testExplicitRootMappingsNeutralizeOnlyStaleRootProvenance() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            (
                "notes/complex-key-before-provenance.md",
                "---\n? [one, two]\n: complex\nagent_provenance:\n  author: another-writer\ntitle: Keep\n"
                    + "---\n\nBody.\n",
                "---\n? [one, two]\n: complex\nformer_writer_attribution:\n"
                    + "  author: another-writer\ntitle: Keep\n---\n\nBody.\n"
            ),
            (
                "notes/explicit-provenance-key.md",
                "---\n? agent_provenance\n: {author: another-writer}\nnext: Keep\n---\n\nBody.\n",
                "---\n? former_writer_attribution\n: {author: another-writer}\n"
                    + "next: Keep\n---\n\nBody.\n"
            ),
            (
                "notes/commented-explicit-provenance-key.md",
                "---\n? agent_provenance # key comment\n: {author: another-writer}\n"
                    + "next: Keep\n---\n\nBody.\n",
                "---\n? former_writer_attribution # key comment\n: {author: another-writer}\n"
                    + "next: Keep\n---\n\nBody.\n"
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
            XCTAssertTrue(saved.contains("another-writer"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testBalancedInvalidFlowRootPreservesEveryByte() async throws {
        struct ProvenanceFailure: Error {}
        let cases = [
            ("notes/invalid-flow-missing-comma.md", "{agent_provenance: old title: Keep}"),
            ("notes/invalid-flow-embedded-collection.md", "{agent_provenance: old [title]}"),
            ("notes/invalid-flow-trailing-node.md", "{agent_provenance: {author: old} title}")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        for (path, frontmatter) in cases {
            let text = "---\n\(frontmatter)\n---\n\nBody.\n"
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        XCTAssertTrue(loggedFailures.values.allSatisfy {
            $0.contains("writing requested bytes without refreshed provenance")
        })
    }

    func testUnbalancedFlowRootPreservesEveryByteAndLogsUnverifiableOutcome() async throws {
        struct ProvenanceFailure: Error {}
        let path = "notes/unbalanced-flow-root.md"
        let text = "---\n{agent_provenance: old\n---\n\nBody.\n"
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
        XCTAssertTrue(loggedFailures.values[0].contains("writing requested bytes without refreshed provenance"))
    }

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
            )
        ]
        let preservedCases = [
            ("notes/sequence-mapping.md", "---\n-\tauthor: human\n  note: keep\n---\n\nBody.\n"),
            ("notes/double-quoted.md", "---\n\"literal: scalar\"\n---\n\nBody.\n"),
            ("notes/single-quoted.md", "---\n'literal: scalar'\n---\n\nBody.\n")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
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
        for (path, text) in preservedCases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
        }
        XCTAssertEqual(loggedFailures.values.count, preservedCases.count)
    }

    func testStructuredProvenanceFailurePreservesPriorWriterUnderNeutralKey() async throws {
        struct ProvenanceFailure: Error {}
        let path = "_heimdal/settings.md"
        let url = tempDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nforeign: keep\nformer_writer_attribution: human-owned\nagent_provenance:\n"
            .appending("  author: another-writer\n")
            .appending("  written_at: old\n  origin: imported\n---\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { throw ProvenanceFailure() },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        try await store.readModifyWrite(path) { document in
            document.frontmatter["updated"] = .bool(true)
        }

        let saved = try await store.read(path)
        XCTAssertTrue(saved.contains("foreign: keep"))
        XCTAssertTrue(saved.contains("updated: true"))
        XCTAssertFalse(saved.contains("agent_provenance"))
        XCTAssertTrue(saved.contains("former_writer_attribution:"))
        XCTAssertTrue(saved.contains("former_writer_attribution_2:"))
        XCTAssertTrue(saved.contains("human-owned"))
        XCTAssertTrue(saved.contains("another-writer"))
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains(path))
        XCTAssertTrue(loggedFailures.values[0].contains("neutralized stale attribution"))
    }
}
