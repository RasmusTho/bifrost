import Foundation

/// Block-level markdown model. Inline styling (`**bold**`, `*italic*`,
/// `` `code` ``, `[text](url)`) is left as raw text inside each block — the
/// renderer hands it to SwiftUI's `Text(LocalizedStringKey:)`, which already
/// supports that inline subset, so this parser only needs to find block
/// boundaries (headings, lists, code fences, quotes, rules, paragraphs).
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bulletItem(text: String, indent: Int)
    case numberedItem(number: Int, text: String, indent: Int)
    case codeBlock(text: String, language: String?)
    case blockquote(text: String)
    case horizontalRule
    case paragraph(text: String)
}

public enum MarkdownDocument {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(.paragraph(text: joined))
            }
            paragraphLines = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let block = matchBlock(lines, &index, line: line, trimmed: trimmed) {
                flushParagraph()
                blocks.append(block)
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// Recognizes one non-paragraph block starting at `index` and advances
    /// `index` past it. Returns `nil` (leaving `index` untouched) when the
    /// line is ordinary paragraph text.
    private static func matchBlock(
        _ lines: [String],
        _ index: inout Int,
        line: String,
        trimmed: String
    ) -> MarkdownBlock? {
        if trimmed.hasPrefix("```") {
            return parseCodeFence(lines, &index, openingLine: trimmed)
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            index += 1
            return .horizontalRule
        }
        if let headingMatch = headingLevel(of: trimmed) {
            index += 1
            return .heading(level: headingMatch.level, text: headingMatch.text)
        }
        if trimmed.hasPrefix("> ") || trimmed == ">" {
            index += 1
            return .blockquote(text: trimmed == ">" ? "" : String(trimmed.dropFirst(2)))
        }
        let indent = leadingIndent(of: line)
        if let bulletText = bulletText(from: trimmed) {
            index += 1
            return .bulletItem(text: bulletText, indent: indent)
        }
        if let numbered = numberedItem(from: trimmed) {
            index += 1
            return .numberedItem(number: numbered.number, text: numbered.text, indent: indent)
        }
        return nil
    }

    private static func parseCodeFence(_ lines: [String], _ index: inout Int, openingLine: String) -> MarkdownBlock {
        let language = String(openingLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var codeLines: [String] = []
        index += 1
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            codeLines.append(lines[index])
            index += 1
        }
        index += 1 // skip closing fence
        let code = codeLines.joined(separator: "\n")
        return .codeBlock(text: code, language: language.isEmpty ? nil : language)
    }

    private static func headingLevel(of line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var chars = Substring(line)
        while chars.first == "#" {
            level += 1
            chars = chars.dropFirst()
        }
        guard level <= 6, chars.first == " " else { return nil }
        return (level, chars.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(from line: String) -> (number: Int, text: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let prefix = line[line.startIndex..<dotIndex]
        guard let number = Int(prefix) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (number, String(line[line.index(after: afterDot)...]))
    }

    private static func leadingIndent(of line: String) -> Int {
        line.prefix { $0 == " " }.count / 2
    }
}
