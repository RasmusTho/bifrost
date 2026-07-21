import Foundation

enum YAMLBlockProvenanceSanitizer {
    static func removingProvenance(in sourceLines: [String], before sourceClosing: Int) -> [String] {
        var lines = sourceLines
        var closing = sourceClosing
        guard let rootIndent = blockMappingRootIndent(in: lines[1..<closing]) else { return lines }
        var index = 1
        while index < closing {
            guard isAgentProvenanceEntry(lines[index], rootIndent: rootIndent) else {
                index += 1
                continue
            }
            let removalIndices = provenanceRemovalIndices(
                in: lines,
                at: index,
                before: closing,
                rootIndent: rootIndent
            )
            for removalIndex in removalIndices.reversed() {
                lines.remove(at: removalIndex)
            }
            closing -= removalIndices.count
        }
        return lines
    }

    private static func provenanceRemovalIndices(
        in lines: [String],
        at start: Int,
        before closing: Int,
        rootIndent: String
    ) -> [Int] {
        let content = String(lines[start].dropFirst(rootIndent.count))
        let spanStart = blockProvenanceSpanStart(
            content: content,
            lines: lines,
            start: start,
            closing: closing,
            rootIndent: rootIndent
        )
        var continuation = YAMLFlowContinuation()
        if let flowNode = YAMLNodeStart.flowCollection(in: spanStart.remainder) {
            continuation.scan(flowNode)
        }
        var indices = spanStart.indices
        var candidate = spanStart.nextCandidate
        while candidate < closing {
            let line = lines[candidate]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                candidate += 1
                continue
            }
            if continuation.isOpen || isNested(line, beneath: rootIndent)
                || isRootSequenceEntry(line, rootIndent: rootIndent) {
                indices.append(candidate)
                continuation.scan(line)
                candidate += 1
                continue
            }
            break
        }
        return indices
    }

    private static func blockProvenanceSpanStart(
        content: String,
        lines: [String],
        start: Int,
        closing: Int,
        rootIndent: String
    ) -> BlockProvenanceSpanStart {
        if let separator = mappingSeparator(in: content) {
            let remainder = String(content[content.index(after: separator)...])
            return BlockProvenanceSpanStart(indices: [start], nextCandidate: start + 1, remainder: remainder)
        }
        var candidate = start + 1
        while candidate < closing {
            let trimmed = lines[candidate].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                candidate += 1
                continue
            }
            guard let remainder = explicitValueRemainder(lines[candidate], rootIndent: rootIndent) else { break }
            return BlockProvenanceSpanStart(
                indices: [start, candidate],
                nextCandidate: candidate + 1,
                remainder: remainder
            )
        }
        return BlockProvenanceSpanStart(indices: [start], nextCandidate: start + 1, remainder: "")
    }

    private static func explicitValueRemainder(_ line: String, rootIndent: String) -> String? {
        guard line.hasPrefix(rootIndent) else { return nil }
        let content = String(line.dropFirst(rootIndent.count))
        guard content.first == ":" else { return nil }
        let afterColon = content.index(after: content.startIndex)
        guard afterColon == content.endIndex || content[afterColon].isWhitespace else { return nil }
        return String(content[afterColon...])
    }

    private static func blockMappingRootIndent(in lines: ArraySlice<String>) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if YAMLNodeStart.containsOnlyProperties(in: line) { continue }
            let indent = String(line.prefix(while: { $0.isWhitespace }))
            let content = String(line.dropFirst(indent.count))
            return mappingSeparator(in: content) != nil || isExplicitMappingEntry(content) ? indent : nil
        }
        return nil
    }

    private static func isAgentProvenanceEntry(_ line: String, rootIndent: String) -> Bool {
        guard line.hasPrefix(rootIndent) else { return false }
        let content = String(line.dropFirst(rootIndent.count))
        guard content.first?.isWhitespace != true else { return false }
        if let separator = mappingSeparator(in: content) {
            return YAMLProvenanceKey.matches(String(content[..<separator]))
        }
        return isExplicitMappingEntry(content) && YAMLProvenanceKey.matches(content)
    }

    private static func isNested(_ line: String, beneath rootIndent: String) -> Bool {
        guard line.hasPrefix(rootIndent) else { return false }
        return line.dropFirst(rootIndent.count).first?.isWhitespace == true
    }

    private static func isRootSequenceEntry(_ line: String, rootIndent: String) -> Bool {
        guard line.hasPrefix(rootIndent) else { return false }
        return isSequenceEntry(String(line.dropFirst(rootIndent.count)))
    }

    private static func isExplicitMappingEntry(_ content: String) -> Bool {
        guard content.first == "?" else { return false }
        let next = content.index(after: content.startIndex)
        return next == content.endIndex || content[next].isWhitespace
    }

    private static func mappingSeparator(in line: String) -> String.Index? {
        line.indices.first(where: { index in
            guard line[index] == ":", index != line.startIndex, !isSequenceEntry(line) else { return false }
            let next = line.index(after: index)
            return next == line.endIndex || line[next].isWhitespace
        })
    }

    private static func isSequenceEntry(_ line: String) -> Bool {
        line.first == "-" && (line.count == 1 || line.dropFirst().first?.isWhitespace == true)
    }
}

enum YAMLProvenanceKey {
    static func matches(_ key: String) -> Bool {
        var candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExplicitMappingEntry(candidate) {
            candidate = String(candidate.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let characters = Array(candidate)
        if let start = characters.indices.first,
           let nodeStart = YAMLNodeStart.index(in: characters, startingAt: start),
           nodeStart != start {
            candidate = String(characters[nodeStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return candidate == "agent_provenance"
            || candidate == "\"agent_provenance\""
            || candidate == "'agent_provenance'"
    }

    private static func isExplicitMappingEntry(_ content: String) -> Bool {
        guard content.first == "?" else { return false }
        let next = content.index(after: content.startIndex)
        return next == content.endIndex || content[next].isWhitespace
    }
}

private struct BlockProvenanceSpanStart {
    let indices: [Int]
    let nextCandidate: Int
    let remainder: String
}
