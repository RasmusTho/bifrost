import XCTest
@testable import Yggdrasil

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
    func testAmbiguousExistingProvenanceIsRemovedAndLogged() async throws {
        let cases = [
            (
                "notes/block-provenance.md",
                "---\ntitle: Keep\nagent_provenance: |\n  legacy attribution\nnext: keep\n---\n\nBody.\n",
                "---\ntitle: Keep\nnext: keep\n---\n\nBody.\n"
            ),
            (
                "notes/separated-provenance.md",
                "---\ntitle: Keep\nagent_provenance:\n  author: old\n# human explanation\n\n"
                    + "  written_at: old\n  origin: imported\nnext: keep\n---\n\nBody.\n",
                "---\ntitle: Keep\n# human explanation\n\nnext: keep\n---\n\nBody.\n"
            ),
            (
                "notes/indentless-sequence.md",
                "---\nagent_provenance:\n-\tauthor: old\nnext: keep\n---\n",
                "---\nnext: keep\n---\n"
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
            XCTAssertFalse(saved.contains("legacy attribution"))
            XCTAssertFalse(saved.contains("author: old"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        for (path, _, _) in cases {
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
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
        # retain this human comment
        tags: [one, two]
        ---

        Body.
        """)
        XCTAssertFalse(saved.contains("agent_provenance"))
        XCTAssertFalse(saved.contains("another-writer"))
        XCTAssertEqual(loggedFailures.values.count, 1)
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
            XCTAssertEqual(saved, "---\ntitle: Keep\nnext: preserve-me\n---\n\nBody.\n")
            XCTAssertFalse(saved.contains("agent_provenance"))
            XCTAssertFalse(saved.contains(staleValue))
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
                + "  next: preserve-me\n---\n\nBody.\n"
        )
        XCTAssertTrue(saved.contains("agent_provenance: nested-human-data"))
        XCTAssertFalse(saved.contains("another-writer"))
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
        let expected = "---\n{title: \"Keep # literal, { brace\", # retain this human comment\n "
            + "\n tags: [one, two]}\n---\n\nBody."
        XCTAssertEqual(saved, expected)
        XCTAssertFalse(saved.contains("agent_provenance"))
        XCTAssertFalse(saved.contains("another-writer"))
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
            XCTAssertEqual(saved, "---\n\(property) { title: Keep}\n---\n\nBody.\n")
            XCTAssertFalse(saved.contains("agent_provenance"))
            XCTAssertFalse(saved.contains("another-writer"))
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
                + "  title: Keep\n---\n\nBody.\n"
            XCTAssertEqual(saved, expected)
            XCTAssertTrue(saved.contains("agent_provenance: nested-human-data"))
            XCTAssertFalse(saved.contains("another-writer"))
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
        for (path, _) in cases {
            XCTAssertTrue(loggedFailures.values.contains { $0.contains(path) })
        }
    }

    func testUnsafeUnprovenancedFrontmatterIsPreservedAndLogged() async throws {
        let cases = [
            ("notes/empty-map.md", "---\n{}\n---\n\nBody.\n"),
            ("notes/flow-map.md", "---\n{tags: [one, two]}\n---\n\nBody.\n"),
            ("notes/sequence-mapping.md", "---\n-\tauthor: human\n  note: keep\n---\n\nBody.\n"),
            ("notes/double-quoted.md", "---\n\"literal: scalar\"\n---\n\nBody.\n"),
            ("notes/single-quoted.md", "---\n'literal: scalar'\n---\n\nBody.\n")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { "2026-07-21T10:30:00Z" },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )
        for (path, text) in cases {
            try await store.write(text, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, text)
        }
        XCTAssertEqual(loggedFailures.values.count, cases.count)
    }

    func testStructuredProvenanceFailureRemovesPriorWriter() async throws {
        struct ProvenanceFailure: Error {}
        let path = "_heimdal/settings.md"
        let url = tempDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nforeign: keep\nagent_provenance:\n  author: another-writer\n"
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
        XCTAssertFalse(saved.contains("another-writer"))
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains(path))
    }
}
