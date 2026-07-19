import XCTest
@testable import YggdrasilCore

final class MarkdownDocumentTests: XCTestCase {
    func testParsesHeadingsListsAndParagraphs() {
        let text = """
        # Title

        Some paragraph text
        that wraps two lines.

        - first item
        - second item

        1. step one
        2. step two

        > a quoted note

        ```swift
        let x = 1
        ```

        ---
        """
        let blocks = MarkdownDocument.parse(text)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .paragraph(text: "Some paragraph text that wraps two lines."))
        XCTAssertEqual(blocks[2], .bulletItem(text: "first item", indent: 0))
        XCTAssertEqual(blocks[3], .bulletItem(text: "second item", indent: 0))
        XCTAssertEqual(blocks[4], .numberedItem(number: 1, text: "step one", indent: 0))
        XCTAssertEqual(blocks[5], .numberedItem(number: 2, text: "step two", indent: 0))
        XCTAssertEqual(blocks[6], .blockquote(text: "a quoted note"))
        XCTAssertEqual(blocks[7], .codeBlock(text: "let x = 1", language: "swift"))
        XCTAssertEqual(blocks[8], .horizontalRule)
    }

    func testNumberedListEdgeCase() {
        XCTAssertEqual(
            MarkdownDocument.parse("3.5 kg is the measured weight."),
            [.paragraph(text: "3.5 kg is the measured weight.")]
        )
    }
}
