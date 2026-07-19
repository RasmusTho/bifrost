import Foundation

/// Parses and serializes the constrained YAML subset used by the `_heimdal/**`
/// note substrate: nested block mappings, block sequences, sequences of
/// mappings, flow scalars, and flow collections (`[a, b]` / `{a: 1}`).
///
/// This is intentionally not a general-purpose YAML engine. The note files it
/// reads are produced by Python's `yaml.safe_dump` (block style, 2-space
/// indent) or by this codec itself, so the subset below is sufficient and its
/// boundaries are known.
public enum YAMLCodec {
    public enum CodecError: Error, Equatable {
        case malformedLine(String)
        case unexpectedEnd
    }

    private struct Line {
        let indent: Int
        let content: String
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> YAMLValue {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [Line] = []
        for raw in rawLines {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let trimmedLeading = raw.drop { $0 == " " }
            let indent = raw.count - trimmedLeading.count
            let content = String(trimmedLeading)
            if content.hasPrefix("#") { continue }
            lines.append(Line(indent: indent, content: content))
        }
        guard !lines.isEmpty else { return .map(YAMLMap()) }
        var index = 0
        let (value, _) = try parseBlock(lines, &index, indent: lines[0].indent)
        return value
    }

    private static func parseBlock(_ lines: [Line], _ index: inout Int, indent: Int) throws -> (YAMLValue, Int) {
        guard index < lines.count else { return (.null, index) }
        if lines[index].content.hasPrefix("-") {
            return (try parseSequence(lines, &index, indent: indent), index)
        }
        return (try parseMapping(lines, &index, indent: indent), index)
    }

    private static func parseSequence(_ lines: [Line], _ index: inout Int, indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while index < lines.count, lines[index].indent == indent, isSequenceMarker(lines[index].content) {
            let content = lines[index].content
            let after = content == "-" ? "" : String(content.dropFirst(2))
            if after.isEmpty {
                index += 1
                guard index < lines.count, lines[index].indent > indent else {
                    items.append(.null)
                    continue
                }
                let (value, _) = try parseBlock(lines, &index, indent: lines[index].indent)
                items.append(value)
            } else if isMapEntry(after) {
                // "- key: value" starts a mapping item; continuation keys are
                // indented to align under the content following "- " (indent + 2).
                let itemIndent = indent + 2
                var synthetic: [Line] = [Line(indent: itemIndent, content: after)]
                index += 1
                while index < lines.count, lines[index].indent == itemIndent, !lines[index].content.hasPrefix("-") {
                    synthetic.append(Line(indent: itemIndent, content: lines[index].content))
                    index += 1
                }
                var synthIndex = 0
                let map = try parseMapping(synthetic, &synthIndex, indent: itemIndent)
                items.append(map)
            } else {
                items.append(try parseScalar(after))
                index += 1
            }
        }
        return .array(items)
    }

    private static func parseMapping(_ lines: [Line], _ index: inout Int, indent: Int) throws -> YAMLValue {
        var map = YAMLMap()
        while index < lines.count, lines[index].indent == indent, !lines[index].content.hasPrefix("-") {
            let content = lines[index].content
            guard let colon = topLevelColon(content) else {
                throw CodecError.malformedLine(content)
            }
            let key = unquote(String(content[content.startIndex..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                index += 1
                if index < lines.count, lines[index].indent > indent {
                    let (value, _) = try parseBlock(lines, &index, indent: lines[index].indent)
                    map[key] = value
                } else {
                    map[key] = .null
                }
            } else {
                map[key] = try parseScalar(rest)
                index += 1
            }
        }
        return .map(map)
    }

    private static func isMapEntry(_ text: String) -> Bool {
        topLevelColon(text) != nil
    }

    private static func isSequenceMarker(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    /// Finds the ':' that separates a key from its value, ignoring colons
    /// inside quoted scalars.
    private static func topLevelColon(_ text: String) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "'" && !inDouble { inSingle.toggle() }
            if char == "\"" && !inSingle { inDouble.toggle() }
            if char == ":" && !inSingle && !inDouble {
                let nextIndex = text.index(after: index)
                if nextIndex == text.endIndex || text[nextIndex] == " " {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func parseScalar(_ raw: String) throws -> YAMLValue {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            let parts = splitFlow(inner)
            return .array(try parts.map { try parseScalar($0) })
        }
        if text.hasPrefix("{") && text.hasSuffix("}") {
            let inner = String(text.dropFirst().dropLast())
            var map = YAMLMap()
            for part in splitFlow(inner) {
                guard let colon = topLevelColon(part) else { continue }
                let key = unquote(String(part[part.startIndex..<colon]).trimmingCharacters(in: .whitespaces))
                let value = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                map[key] = try parseScalar(value)
            }
            return .map(map)
        }
        if text.isEmpty || text == "~" || text == "null" || text == "Null" || text == "NULL" {
            return .null
        }
        if text == "true" || text == "True" || text == "TRUE" { return .bool(true) }
        if text == "false" || text == "False" || text == "FALSE" { return .bool(false) }
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return .string(unquote(text))
        }
        // Preserve a leading-zero scalar as text. Parsing it as an Int would
        // discard the spelling on write and can change a note field that this
        // client does not own.
        if hasLeadingZeroInteger(text) { return .string(text) }
        if let intValue = Int(text) { return .int(intValue) }
        if let doubleValue = Double(text) { return .double(doubleValue) }
        return .string(text)
    }

    private static func hasLeadingZeroInteger(_ text: String) -> Bool {
        guard text.count > 1, text.first == "0" else { return false }
        return text.dropFirst().allSatisfy(\.isNumber)
    }

    private static func splitFlow(_ text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var parts: [String] = []
        var depth = 0
        var inSingle = false
        var inDouble = false
        var current = ""
        for char in text {
            if char == "'" && !inDouble { inSingle.toggle() }
            if char == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if char == "[" || char == "{" { depth += 1 }
                if char == "]" || char == "}" { depth -= 1 }
                if char == "," && depth == 0 {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
            }
            current.append(char)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current.trimmingCharacters(in: .whitespaces))
        }
        return parts
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.hasPrefix("\"") && text.hasSuffix("\"") {
            return unescapeDoubleQuoted(String(text.dropFirst().dropLast()))
        }
        if text.hasPrefix("'") && text.hasSuffix("'") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Decodes the small set of backslash escapes `dumpString` emits, one
    /// character at a time (not via chained global replacements, which would
    /// misparse an escaped backslash immediately followed by a literal 'n').
    private static func unescapeDoubleQuoted(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            guard char == "\\" else {
                result.append(char)
                continue
            }
            guard let next = iterator.next() else {
                result.append(char)
                break
            }
            switch next {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            default:
                result.append(char)
                result.append(next)
            }
        }
        return result
    }
}
