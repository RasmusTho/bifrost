import Foundation

/// Serialization half of `YAMLCodec`, split into its own file/extension so
/// the parsing and serialization bodies are each independently reasonably
/// sized rather than one large type.
extension YAMLCodec {
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
                lines.append(dumpSequenceMapItem(nested, pad: pad, indent: indent))
            default:
                lines.append("\(pad)- \(dumpScalar(item))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func dumpSequenceMapItem(_ nested: YAMLMap, pad: String, indent: Int) -> String {
        var lines: [String] = []
        for (offset, pair) in nested.pairs.enumerated() {
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
        let containsNewline = text.contains("\n") || text.contains("\r")
        let needsQuoting = containsNewline || text.hasPrefix(" ") || text.hasSuffix(" ")
            || text.contains(": ") || text.hasSuffix(":")
            || "-?:[]{}#&*!|>'\"%@`".contains(firstCharacter)
            || text == "true" || text == "false" || text == "null" || text == "~"
            || (Int(text) != nil && !hasLeadingZeroInteger(text))
            || (Double(text) != nil && !hasLeadingZeroInteger(text))
        guard needsQuoting else { return text }
        // Double-quoted scalars must stay single-line for this codec's parser, so embedded
        // newlines are escaped as literal "\n"/"\r" rather than left as raw line breaks.
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func hasLeadingZeroInteger(_ text: String) -> Bool {
        guard text.count > 1, text.first == "0" else { return false }
        return text.dropFirst().allSatisfy(\.isNumber)
    }
}
