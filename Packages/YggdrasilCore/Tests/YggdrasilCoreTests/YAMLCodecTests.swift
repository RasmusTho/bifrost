import XCTest
@testable import YggdrasilCore

final class YAMLCodecTests: XCTestCase {
    func testFlatScalarsRoundTrip() throws {
        let yaml = """
        schema_version: "1.0"
        retention_window_days: 30
        last_enforced_at: 2026-07-01T00:00:00Z
        """
        let value = try YAMLCodec.parse(yaml)
        guard case .map(let map) = value else { return XCTFail("expected map") }
        XCTAssertEqual(map["schema_version"]?.stringValue, "1.0")
        XCTAssertEqual(map["retention_window_days"]?.intValue, 30)
    }

    func testLeadingZeroScalarRoundTripsVerbatim() throws {
        let yaml = "ticket: 007\n"
        XCTAssertEqual(YAMLCodec.serialize(try YAMLCodec.parse(yaml)), yaml)
    }

    func testUnsupportedBlockScalarFailsInsteadOfPartiallyParsing() {
        let yaml = "description: |\n  first line\nafter: preserved\n"

        XCTAssertThrowsError(try YAMLCodec.parse(yaml))
    }

    func testStringWithEmbeddedNewlineRoundTrips() throws {
        var map = YAMLMap()
        map["note"] = .string("line one\nline two")
        map["backslash_n"] = .string("literal backslash then n: \\n")
        let serialized = YAMLCodec.serialize(.map(map))
        let lineCount = serialized.split(separator: "\n", omittingEmptySubsequences: false).count
        let message = "a raw newline inside a scalar would break this codec's line-based parser: \(serialized)"
        XCTAssertEqual(lineCount, 3, message)

        let reparsed = try YAMLCodec.parse(serialized)
        guard case .map(let reparsedMap) = reparsed else { return XCTFail("expected map") }
        XCTAssertEqual(reparsedMap["note"]?.stringValue, "line one\nline two")
        XCTAssertEqual(reparsedMap["backslash_n"]?.stringValue, "literal backslash then n: \\n")
    }

    func testBlockSequenceOfScalars() throws {
        let yaml = """
        watched:
          - "example.com"
          - "another.com"
        last_synced: 2026-07-01T00:00:00Z
        """
        let value = try YAMLCodec.parse(yaml)
        guard case .map(let map) = value else { return XCTFail("expected map") }
        XCTAssertEqual(map["watched"]?.stringArray, ["example.com", "another.com"])
    }

    func testSequenceOfMappings() throws {
        let yaml = """
        pending:
          - queue_entry_id: q1
            mention_id: m1
            surface_form: "Alice"
            resolution: candidate
            confidence: 0.82
          - queue_entry_id: q2
            mention_id: m2
            surface_form: "Bob"
            resolution: candidate
            confidence: 0.5
        """
        let value = try YAMLCodec.parse(yaml)
        guard case .map(let map) = value, let items = map["pending"]?.arrayValue else {
            return XCTFail("expected pending array")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].mapValue?["surface_form"]?.stringValue, "Alice")
        XCTAssertEqual(items[1].mapValue?["confidence"]?.doubleValue, 0.5)
    }

    func testNestedDictOfScalars() throws {
        let yaml = """
        weights:
          reading: 0.7
          writing: 0.3
        """
        let value = try YAMLCodec.parse(yaml)
        guard case .map(let map) = value, let weights = map["weights"]?.mapValue else {
            return XCTFail("expected weights map")
        }
        XCTAssertEqual(weights["reading"]?.doubleValue, 0.7)
        XCTAssertEqual(weights["writing"]?.doubleValue, 0.3)
    }

    func testEmptyCollectionsSerializeAsFlow() {
        var map = YAMLMap()
        map["watched"] = .array([])
        map["weights"] = .map(YAMLMap())
        let text = YAMLCodec.serialize(.map(map))
        XCTAssertTrue(text.contains("watched: []"))
        XCTAssertTrue(text.contains("weights: {}"))
    }

    func testRoundTripPreservesUnknownFields() throws {
        let original = """
        schema_version: "1.0"
        weights:
          reading: 0.7
        observed_signal:
          reading: 12
        """
        var doc = try FrontmatterDocument.parse("---\n\(original)\n---\n\nBody text.\n")
        var note = InterestsNote(document: doc)
        note.setWeight(0.9, for: "reading")
        doc = note.document

        // The field this client doesn't own must survive untouched.
        XCTAssertEqual(doc.frontmatter["observed_signal"]?.mapValue?["reading"]?.intValue, 12)
        XCTAssertEqual(doc.frontmatter["weights"]?.mapValue?["reading"]?.doubleValue, 0.9)

        let rendered = doc.rendered()
        let reparsed = try FrontmatterDocument.parse(rendered)
        XCTAssertEqual(reparsed.frontmatter["observed_signal"]?.mapValue?["reading"]?.intValue, 12)
    }
}
