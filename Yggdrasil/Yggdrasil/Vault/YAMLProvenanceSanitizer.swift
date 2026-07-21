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

        guard let rootIndent = blockMappingRootIndent(in: lines[1..<closingIndex]) else {
            return lines.joined(separator: newline)
        }
        var index = 1
        while index < closingIndex {
            guard isAgentProvenanceEntry(lines[index], rootIndent: rootIndent) else {
                index += 1
                continue
            }
            let removalIndices = provenanceRemovalIndices(
                in: lines,
                at: index,
                before: closingIndex,
                rootIndent: rootIndent
            )
            for removalIndex in removalIndices.reversed() {
                lines.remove(at: removalIndex)
            }
            closingIndex -= removalIndices.count
        }
        return lines.joined(separator: newline)
    }

    private static func provenanceRemovalIndices(
        in lines: [String],
        at start: Int,
        before closing: Int,
        rootIndent: String
    ) -> [Int] {
        let content = String(lines[start].dropFirst(rootIndent.count))
        guard let separator = mappingSeparator(in: content) else { return [start] }
        let remainder = String(content[content.index(after: separator)...])
        var continuation = YAMLFlowContinuation()
        if let flowNode = YAMLNodeStart.flowCollection(in: remainder) { continuation.scan(flowNode) }
        var indices = [start]
        var candidate = start + 1
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
        guard let contentStart = firstYAMLContentIndex(in: characters),
              let rootStart = YAMLNodeStart.index(in: characters, startingAt: contentStart),
              characters[rootStart] == "{",
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

    private static func blockMappingRootIndent(in lines: ArraySlice<String>) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = String(line.prefix(while: { $0.isWhitespace }))
            let content = String(line.dropFirst(indent.count))
            return mappingSeparator(in: content) == nil ? nil : indent
        }
        return nil
    }

    private static func isAgentProvenanceEntry(_ line: String, rootIndent: String) -> Bool {
        guard line.hasPrefix(rootIndent) else { return false }
        let content = String(line.dropFirst(rootIndent.count))
        guard content.first?.isWhitespace != true,
              let separator = mappingSeparator(in: content) else { return false }
        let key = content[..<separator].trimmingCharacters(in: .whitespaces)
        return isAgentProvenanceKey(key)
    }

    private static func isNested(_ line: String, beneath rootIndent: String) -> Bool {
        guard line.hasPrefix(rootIndent) else { return false }
        return line.dropFirst(rootIndent.count).first?.isWhitespace == true
    }

    private static func isRootSequenceEntry(_ line: String, rootIndent: String) -> Bool {
        guard line.hasPrefix(rootIndent) else { return false }
        return isSequenceEntry(String(line.dropFirst(rootIndent.count)))
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

private enum YAMLNodeStart {
    static func flowCollection(in text: String) -> String? {
        let characters = Array(text)
        guard let contentStart = contentIndex(in: characters, range: characters.indices),
              let nodeStart = index(in: characters, startingAt: contentStart),
              characters[nodeStart] == "{" || characters[nodeStart] == "[" else {
            return nil
        }
        return String(characters[nodeStart...])
    }

    static func index(in characters: [Character], startingAt start: Int) -> Int? {
        var nodeIndex = start
        while nodeIndex < characters.count, characters[nodeIndex] == "!" || characters[nodeIndex] == "&" {
            guard let propertyEnd = propertyEnd(in: characters, startingAt: nodeIndex),
                  propertyEnd < characters.count,
                  characters[propertyEnd].isWhitespace || characters[propertyEnd] == "#",
                  let next = contentIndex(in: characters, range: propertyEnd..<characters.count) else {
                return nil
            }
            nodeIndex = next
        }
        return nodeIndex
    }

    private static func propertyEnd(in characters: [Character], startingAt start: Int) -> Int? {
        if characters[start] == "!", start + 1 < characters.count, characters[start + 1] == "<" {
            guard let closing = characters[(start + 2)...].firstIndex(of: ">") else { return nil }
            return closing + 1
        }
        var index = start + 1
        while index < characters.count,
              !characters[index].isWhitespace,
              !"[]{},".contains(characters[index]) {
            index += 1
        }
        return index > start + 1 ? index : nil
    }

    private static func contentIndex(in characters: [Character], range: Range<Int>) -> Int? {
        var inComment = false
        for index in range {
            let character = characters[index]
            if inComment {
                if character == "\n" || character == "\r" { inComment = false }
            } else if character == "#" {
                inComment = true
            } else if !character.isWhitespace {
                return index
            }
        }
        return nil
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
