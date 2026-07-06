import XCTest
@testable import YggdrasilCore

final class FrontmatterDocumentTests: XCTestCase {
    func testParsesFrontmatterAndBody() throws {
        let text = """
        ---
        artifact_class: heimdal_control
        retention_window_days: 14
        ---

        # Settings

        Body content.
        """
        let doc = try FrontmatterDocument.parse(text)
        XCTAssertEqual(doc.frontmatter["retention_window_days"]?.intValue, 14)
        XCTAssertTrue(doc.body.contains("# Settings"))
    }

    func testRenderedRoundTripsExactFieldSet() throws {
        let text = "---\nartifact_class: heimdal_control\ncounts:\n  attended:12: 3\n---\n\nSome body.\n"
        let doc = try FrontmatterDocument.parse(text)
        let rendered = doc.rendered()
        let reparsed = try FrontmatterDocument.parse(rendered)
        XCTAssertEqual(reparsed.frontmatter, doc.frontmatter)
        XCTAssertEqual(reparsed.body.trimmingCharacters(in: .whitespacesAndNewlines), "Some body.")
    }

    func testMissingFrontmatterThrows() {
        XCTAssertThrowsError(try FrontmatterDocument.parse("# No frontmatter here"))
    }
}
