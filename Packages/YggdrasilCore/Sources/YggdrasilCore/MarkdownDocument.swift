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

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1 // skip closing fence
                blocks.append(.codeBlock(text: codeLines.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.horizontalRule)
                index += 1
                continue
            }

            if let headingMatch = headingLevel(of: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: headingMatch.level, text: headingMatch.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let quoteText = trimmed == ">" ? "" : String(trimmed.dropFirst(2))
                blocks.append(.blockquote(text: quoteText))
                index += 1
                continue
            }

            let indent = leadingIndent(of: line)
            if let bulletText = bulletText(from: trimmed) {
                flushParagraph()
                blocks.append(.bulletItem(text: bulletText, indent: indent))
                index += 1
                continue
            }

            if let numbered = numberedItem(from: trimmed) {
                flushParagraph()
                blocks.append(.numberedItem(number: numbered.number, text: numbered.text, indent: indent))
                index += 1
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
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
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                return String(line.dropFirst(marker.count))
            }
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
