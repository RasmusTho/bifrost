import XCTest
@testable import Yggdrasil

extension VaultFileStoreTests {
    func testYAML12AnchorNamesRefreshThroughProductionWrite() async throws {
        let timestamp = "2026-07-24T06:40:00Z"
        let cases = [
            ("notes/punctuation-anchor.md",
             "---\nbase: &base.one {agent_provenance: stale, keep: punctuation}\n"
                + "<<: *base.one\nforeign: punctuation\n---\n",
             "---\nbase: &base.one {former_writer_attribution: stale, keep: punctuation}\n"
                + "<<: *base.one\nforeign: punctuation\n"
                + "agent_provenance:\n  author: bifrost-ios\n  written_at: \(timestamp)\n"
                + "  origin: direct-fs\n---\n"),
            ("notes/unicode-anchor.md",
             "---\nbase: &båse {agent_provenance: stale, keep: ångström}\n"
                + "<<: *båse\nforeign: unicode\n---\n",
             "---\nbase: &båse {former_writer_attribution: stale, keep: ångström}\n"
                + "<<: *båse\nforeign: unicode\n"
                + "agent_provenance:\n  author: bifrost-ios\n  written_at: \(timestamp)\n"
                + "  origin: direct-fs\n---\n")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, input, expected) in cases {
            try await store.write(input, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected, path)
        }
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }

    func testRepeatedAnchorNamesRefreshTheNearestBoundSource() async throws {
        let timestamp = "2026-07-23T21:20:00Z"
        let cases = [
            ("notes/reused-flow-anchor.md",
             "---\nfirst: &same {foreign: one}\nforeign_use: *same\n"
                + "second: &same {agent_provenance: second}\n<<: *same\n---\n",
             "---\nfirst: &same {foreign: one}\nforeign_use: *same\n"
                + "second: &same {former_writer_attribution: second}\n<<: *same\n"
                + "agent_provenance:\n  author: bifrost-ios\n  written_at: \(timestamp)\n"
                + "  origin: direct-fs\n---\n"),
            ("notes/reused-block-anchor.md",
             "---\nfirst: &same\n  foreign: one\nforeign_use: *same\n"
                + "second: &same\n  agent_provenance: second\n<<: *same\n---\n",
             "---\nfirst: &same\n  foreign: one\nforeign_use: *same\n"
                + "second: &same\n  former_writer_attribution: second\n<<: *same\n"
                + "agent_provenance:\n  author: bifrost-ios\n  written_at: \(timestamp)\n"
                + "  origin: direct-fs\n---\n")
        ]
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { timestamp },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        for (path, input, expected) in cases {
            try await store.write(input, to: path)
            let saved = try await store.read(path)
            XCTAssertEqual(saved, expected, path)
        }
        XCTAssertTrue(loggedFailures.values.isEmpty)
    }

    func testTransitiveMergeWrapperForeignConsumerPreservesEveryByte() async throws {
        let path = "notes/transitive-foreign-alias.md"
        let input = """
        ---
        base: &base {agent_provenance: stale, keep: base}
        wrapper: &wrapper {<<: *base, keep: wrapper}
        <<: *wrapper
        foreign: *wrapper
        ---
        """
        let loggedFailures = MutationValueRecorder()
        let store = VaultFileStore(
            rootURL: tempDirectory,
            provenanceTimestampProvider: { "2026-07-24T06:40:00Z" },
            provenanceFailureLogger: { loggedFailures.record($0) }
        )

        try await store.write(input, to: path)

        let saved = try await store.read(path)
        XCTAssertEqual(saved, input)
        XCTAssertEqual(loggedFailures.values.count, 1)
        XCTAssertTrue(loggedFailures.values[0].contains(path))
        XCTAssertTrue(
            loggedFailures.values[0].contains(
                "writing requested bytes without refreshed provenance"
            )
        )
    }
}
