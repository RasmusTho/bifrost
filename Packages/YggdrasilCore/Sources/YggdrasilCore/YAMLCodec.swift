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
        while index < lines.count, lines[index].indent == indent, lines[index].content == "-" || lines[index].content.hasPrefix("- ") {
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
        if let intValue = Int(text) { return .int(intValue) }
        if let doubleValue = Double(text) { return .double(doubleValue) }
        return .string(text)
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
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    // MARK: Serialization

    public static func serialize(_ value: YAMLValue) -> String {
        guard case .map(let map) = value else {
            return dumpScalar(value) + "\n"
        }
        return dump(map: map, indent: 0)
    }

    private static func dump(map: YAMLMap, indent: Int) -> String {
        guard !map.isEmpty else { return String(repeating: " ", count: indent) + "{}\n" }
        var lines: [String] = []
        let pad = String(repeating: " ", count: indent)
        for (key, value) in map.pairs {
            switch value {
            case .array(let items):
                if items.isEmpty {
                    lines.append("\(pad)\(key): []")
                } else {
                    lines.append("\(pad)\(key):")
                    lines.append(dumpSequenceItems(items, indent: indent + 2))
                }
            case .map(let nested):
                if nested.isEmpty {
                    lines.append("\(pad)\(key): {}")
                } else {
                    lines.append("\(pad)\(key):")
                    lines.append(dump(map: nested, indent: indent + 2))
                }
            default:
                lines.append("\(pad)\(key): \(dumpScalar(value))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func dumpSequenceItems(_ items: [YAMLValue], indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        for item in items {
            switch item {
            case .map(let nested) where !nested.isEmpty:
                let pairs = nested.pairs
                for (offset, pair) in pairs.enumerated() {
                    let (key, value) = pair
                    let linePad = offset == 0 ? pad + "- " : pad + "  "
                    switch value {
                    case .array(let nestedItems):
                        if nestedItems.isEmpty {
                            lines.append("\(linePad)\(key): []")
                        } else {
                            lines.append("\(linePad)\(key):")
                            lines.append(dumpSequenceItems(nestedItems, indent: indent + 4))
                        }
                    case .map(let deeperMap):
                        if deeperMap.isEmpty {
                            lines.append("\(linePad)\(key): {}")
                        } else {
                            lines.append("\(linePad)\(key):")
                            lines.append(dump(map: deeperMap, indent: indent + 4))
                        }
                    default:
                        lines.append("\(linePad)\(key): \(dumpScalar(value))")
                    }
                }
            default:
                lines.append("\(pad)- \(dumpScalar(item))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func dumpScalar(_ value: YAMLValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let intValue): return String(intValue)
        case .double(let doubleValue): return String(doubleValue)
        case .string(let stringValue): return dumpString(stringValue)
        case .array(let items):
            return "[" + items.map { dumpScalar($0) }.joined(separator: ", ") + "]"
        case .map(let nested):
            return "{" + nested.pairs.map { "\($0.0): \(dumpScalar($0.1))" }.joined(separator: ", ") + "}"
        }
    }

    private static func dumpString(_ text: String) -> String {
        guard let firstCharacter = text.first else { return "\"\"" }
        let needsQuoting = text.hasPrefix(" ") || text.hasSuffix(" ")
            || text.contains(": ") || text.hasSuffix(":")
            || "-?:[]{}#&*!|>'\"%@`".contains(firstCharacter)
            || text == "true" || text == "false" || text == "null" || text == "~"
            || Int(text) != nil || Double(text) != nil
        guard needsQuoting else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
