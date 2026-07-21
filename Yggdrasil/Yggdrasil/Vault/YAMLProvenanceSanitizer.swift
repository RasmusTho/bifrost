import Foundation

/// Removes stale top-level writer attribution after provenance tagging fails.
/// Foreign YAML, comments, and whitespace remain byte-for-byte unchanged.
enum YAMLProvenanceSanitizer {
    static func removingExistingProvenance(from text: String) -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        guard text.hasPrefix("---\(newline)") else { return text }
        var lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              var closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return text
        }

        let frontmatter = lines[1..<closingIndex].joined(separator: newline)
        if let cleanedFlowRoot = removingFlowRootProvenance(from: frontmatter) {
            let replacement = cleanedFlowRoot.components(separatedBy: newline)
            lines.replaceSubrange(1..<closingIndex, with: replacement)
            closingIndex = 1 + replacement.count
        }

        var index = 1
        while index < closingIndex {
            guard isAgentProvenanceEntry(lines[index]) else {
                index += 1
                continue
            }
            let removalIndices = provenanceRemovalIndices(in: lines, at: index, before: closingIndex)
            for removalIndex in removalIndices.reversed() {
                lines.remove(at: removalIndex)
            }
            closingIndex -= removalIndices.count
        }
        return lines.joined(separator: newline)
    }

    private static func provenanceRemovalIndices(in lines: [String], at start: Int, before closing: Int) -> [Int] {
        guard let separator = mappingSeparator(in: lines[start]) else { return [start] }
        let remainder = String(lines[start][lines[start].index(after: separator)...])
        var continuation = YAMLFlowContinuation()
        continuation.scan(remainder)
        var indices = [start]
        var candidate = start + 1
        while candidate < closing {
            let line = lines[candidate]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                candidate += 1
                continue
            }
            if continuation.isOpen || line.first?.isWhitespace == true || isSequenceEntry(trimmed) {
                indices.append(candidate)
                continuation.scan(line)
                candidate += 1
                continue
            }
            break
        }
        return indices
    }

    private static func removingFlowRootProvenance(from frontmatter: String) -> String? {
        var characters = Array(frontmatter)
        var removedProvenance = false
        while let indices = flowRootProvenanceRemovalIndices(in: characters) {
            let removal = Set(indices)
            characters = characters.enumerated().compactMap { index, character in
                removal.contains(index) ? nil : character
            }
            removedProvenance = true
        }
        return removedProvenance ? String(characters) : nil
    }

    private static func flowRootProvenanceRemovalIndices(in characters: [Character]) -> [Int]? {
        guard let rootStart = firstYAMLContentIndex(in: characters), characters[rootStart] == "{",
              let rootEnd = flowRootEndIndex(in: characters, rootStart: rootStart),
              onlyYAMLTriviaFollows(rootEnd, in: characters) else {
            return nil
        }

        var state = YAMLFlowParseState(curlyDepth: 1)
        var entryStart = rootStart + 1
        var previousComma: Int?
        for index in entryStart..<rootEnd {
            let character = characters[index]
            if state.consume(character, context: characterContext(at: index, in: characters)) { continue }
            state.trackDepth(character)
            guard character == ",", state.isAtRootMappingDepth else { continue }
            if let removal = flowEntryRemovalIndices(
                in: characters,
                entryStart: entryStart,
                entryEnd: index,
                followingComma: index,
                previousComma: previousComma
            ) {
                return removal
            }
            previousComma = index
            entryStart = index + 1
        }
        return flowEntryRemovalIndices(
            in: characters,
            entryStart: entryStart,
            entryEnd: rootEnd,
            followingComma: nil,
            previousComma: previousComma
        )
    }

    private static func flowRootEndIndex(in characters: [Character], rootStart: Int) -> Int? {
        var state = YAMLFlowParseState(curlyDepth: 1)
        for index in (rootStart + 1)..<characters.count {
            let character = characters[index]
            if state.consume(character, context: characterContext(at: index, in: characters)) { continue }
            state.trackDepth(character)
            if state.curlyDepth == 0, state.squareDepth == 0 { return index }
        }
        return nil
    }

    private static func flowEntryRemovalIndices(
        in characters: [Character],
        entryStart: Int,
        entryEnd: Int,
        followingComma: Int?,
        previousComma: Int?
    ) -> [Int]? {
        guard let keyStart = firstYAMLContentIndex(in: characters, range: entryStart..<entryEnd),
              let separator = flowMappingSeparator(in: characters, range: keyStart..<entryEnd) else {
            return nil
        }
        let key = String(characters[keyStart..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAgentProvenanceKey(key) else { return nil }

        var removal = Array(keyStart..<entryEnd)
        if let followingComma {
            removal.append(followingComma)
        } else if let previousComma {
            removal.append(previousComma)
        }
        return removal
    }

    private static func flowMappingSeparator(in characters: [Character], range: Range<Int>) -> Int? {
        var state = YAMLFlowParseState()
        for index in range {
            let character = characters[index]
            if state.consume(character, context: characterContext(at: index, in: characters)) { continue }
            if character == ":", state.isOutsideFlowCollection { return index }
            state.trackDepth(character)
        }
        return nil
    }

    private static func firstYAMLContentIndex(
        in characters: [Character],
        range: Range<Int>? = nil
    ) -> Int? {
        let bounds = range ?? characters.indices
        var inComment = false
        for index in bounds {
            let character = characters[index]
            if inComment {
                if character == "\n" || character == "\r" { inComment = false }
                continue
            }
            if character == "#" {
                inComment = true
            } else if !character.isWhitespace {
                return index
            }
        }
        return nil
    }

    private static func onlyYAMLTriviaFollows(_ rootEnd: Int, in characters: [Character]) -> Bool {
        firstYAMLContentIndex(in: characters, range: (rootEnd + 1)..<characters.count) == nil
    }

    private static func characterContext(at index: Int, in characters: [Character]) -> YAMLCharacterContext {
        let previous = index > 0 ? characters[index - 1] : nil
        let nextIndex = index + 1
        let next = nextIndex < characters.count ? characters[nextIndex] : nil
        return YAMLCharacterContext(previous: previous, next: next)
    }

    private static func isAgentProvenanceEntry(_ line: String) -> Bool {
        guard line.first?.isWhitespace != true,
              let separator = mappingSeparator(in: line) else { return false }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return isAgentProvenanceKey(key)
    }

    private static func isAgentProvenanceKey(_ key: String) -> Bool {
        key == "agent_provenance" || key == "\"agent_provenance\"" || key == "'agent_provenance'"
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

private struct YAMLCharacterContext {
    let previous: Character?
    let next: Character?
}

private struct YAMLFlowContinuation {
    private var state = YAMLFlowParseState()

    var isOpen: Bool {
        state.curlyDepth > 0 || state.squareDepth > 0 || state.quote != nil
    }

    mutating func scan(_ line: String) {
        let characters = Array(line)
        for index in characters.indices {
            let character = characters[index]
            let previous = index > 0 ? characters[index - 1] : nil
            let nextIndex = index + 1
            let next = nextIndex < characters.count ? characters[nextIndex] : nil
            let context = YAMLCharacterContext(previous: previous, next: next)
            if !state.consume(character, context: context) { state.trackDepth(character, clamped: true) }
        }
        state.inComment = false
    }
}

private struct YAMLFlowParseState {
    var curlyDepth = 0
    var squareDepth = 0
    var quote: YAMLQuote?
    var inComment = false
    private var escapingDoubleQuote = false
    private var skipNextSingleQuote = false

    init(curlyDepth: Int = 0) {
        self.curlyDepth = curlyDepth
    }

    var isAtRootMappingDepth: Bool { curlyDepth == 1 && squareDepth == 0 }
    var isOutsideFlowCollection: Bool { curlyDepth == 0 && squareDepth == 0 }

    mutating func consume(_ character: Character, context: YAMLCharacterContext) -> Bool {
        if consumeComment(character) { return true }
        if consumeSkippedSingleQuote() { return true }
        switch quote {
        case .double:
            consumeDoubleQuoted(character)
            return true
        case .single:
            consumeSingleQuoted(character, next: context.next)
            return true
        case nil:
            return consumeUnquoted(character, previous: context.previous)
        }
    }

    mutating func trackDepth(_ character: Character, clamped: Bool = false) {
        switch character {
        case "{": curlyDepth += 1
        case "}": curlyDepth = clamped ? max(0, curlyDepth - 1) : curlyDepth - 1
        case "[": squareDepth += 1
        case "]": squareDepth = clamped ? max(0, squareDepth - 1) : squareDepth - 1
        default: break
        }
    }

    private mutating func consumeComment(_ character: Character) -> Bool {
        guard inComment else { return false }
        if character == "\n" || character == "\r" { inComment = false }
        return true
    }

    private mutating func consumeSkippedSingleQuote() -> Bool {
        guard skipNextSingleQuote else { return false }
        skipNextSingleQuote = false
        return true
    }

    private mutating func consumeDoubleQuoted(_ character: Character) {
        if escapingDoubleQuote {
            escapingDoubleQuote = false
        } else if character == "\\" {
            escapingDoubleQuote = true
        } else if character == "\"" {
            quote = nil
        }
    }

    private mutating func consumeSingleQuoted(_ character: Character, next: Character?) {
        if character == "'", next == "'" {
            skipNextSingleQuote = true
        } else if character == "'" {
            quote = nil
        }
    }

    private mutating func consumeUnquoted(_ character: Character, previous: Character?) -> Bool {
        if character == "#", previous == nil || previous?.isWhitespace == true {
            inComment = true
            return true
        }
        if character == "\"" {
            quote = .double
            return true
        }
        if character == "'" {
            quote = .single
            return true
        }
        return false
    }
}

private enum YAMLQuote {
    case single
    case double
}
