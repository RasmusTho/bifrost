import Foundation

struct YAMLProvenanceSanitization {
    let text: String
    let neutralizedStaleAttribution: Bool
}

/// Neutralizes only a proven top-level provenance key after refresh fails.
/// The prior value and every foreign byte remain untouched for recovery/audit.
enum YAMLProvenanceSanitizer {
    static func sanitizingFallback(_ text: String) -> YAMLProvenanceSanitization {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        guard text.hasPrefix("---\(newline)") else {
            return YAMLProvenanceSanitization(text: text, neutralizedStaleAttribution: false)
        }
        var lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else {
            return YAMLProvenanceSanitization(text: text, neutralizedStaleAttribution: false)
        }

        let frontmatter = lines[1..<closing].joined(separator: newline)
        let flowResult = neutralizingFlowRootProvenance(in: frontmatter)
        if flowResult.neutralized {
            let replacement = flowResult.text.components(separatedBy: newline)
            lines.replaceSubrange(1..<closing, with: replacement)
        }
        let updatedClosing = lines.dropFirst().firstIndex(of: "---") ?? closing
        let updatedFrontmatter = lines[1..<updatedClosing].joined(separator: "\n")
        let blockResult = YAMLBlockProvenanceSanitizer.neutralizingProvenance(
            in: lines,
            before: updatedClosing,
            aliases: YAMLProvenanceAnchorBindings(text: updatedFrontmatter)
        )
        return YAMLProvenanceSanitization(
            text: blockResult.lines.joined(separator: newline),
            neutralizedStaleAttribution: flowResult.neutralized || blockResult.neutralized
        )
    }

    private static func neutralizingFlowRootProvenance(in frontmatter: String) -> (text: String, neutralized: Bool) {
        var characters = Array(frontmatter)
        var neutralized = false
        while let match = flowRootProvenanceKeyRange(
            in: characters,
            aliases: YAMLProvenanceAnchorBindings(text: String(characters))
        ) {
            let neutralName = YAMLProvenanceKey.availableNeutralName(in: String(characters))
            characters.replaceSubrange(match, with: Array(neutralName))
            neutralized = true
        }
        return (String(characters), neutralized)
    }

    private static func flowRootProvenanceKeyRange(
        in characters: [Character],
        aliases: YAMLProvenanceAnchorBindings
    ) -> Range<Int>? {
        guard let contentStart = firstYAMLContentIndex(in: characters),
              let rootStart = YAMLNodeStart.index(in: characters, startingAt: contentStart),
              characters[rootStart] == "{",
              let rootEnd = flowRootEndIndex(in: characters, rootStart: rootStart),
              onlyYAMLTriviaFollows(rootEnd, in: characters) else {
            return nil
        }

        var state = YAMLFlowParseState(curlyDepth: 1)
        var entryStart = rootStart + 1
        for index in entryStart..<rootEnd {
            let character = characters[index]
            if state.consume(character, context: characterContext(at: index, in: characters)) { continue }
            state.trackDepth(character)
            guard character == ",", state.isAtRootMappingDepth else { continue }
            if let range = flowEntryProvenanceKeyRange(
                in: characters,
                range: entryStart..<index,
                aliases: aliases
            ) {
                return range
            }
            entryStart = index + 1
        }
        return flowEntryProvenanceKeyRange(
            in: characters,
            range: entryStart..<rootEnd,
            aliases: aliases
        )
    }

    private static func flowEntryProvenanceKeyRange(
        in characters: [Character],
        range: Range<Int>,
        aliases: YAMLProvenanceAnchorBindings
    ) -> Range<Int>? {
        guard let keyStart = firstYAMLContentIndex(in: characters, range: range),
              let separator = firstFlowMappingSeparator(
                  in: characters,
                  range: keyStart..<range.upperBound,
                  aliases: aliases
              ),
              let match = YAMLProvenanceKey.replacementMatch(
                  in: String(characters[keyStart..<separator]),
                  activeAliases: aliases.activeNames(before: keyStart)
              ) else {
            return nil
        }
        return (keyStart + match.range.lowerBound)..<(keyStart + match.range.upperBound)
    }

    private static func firstFlowMappingSeparator(
        in characters: [Character],
        range: Range<Int>,
        aliases: YAMLProvenanceAnchorBindings
    ) -> Int? {
        var state = YAMLFlowParseState()
        for index in range {
            let character = characters[index]
            if state.consume(character, context: characterContext(at: index, in: characters)) { continue }
            if character == ":", state.isOutsideFlowCollection,
               YAMLProvenanceKey.replacementMatch(
                   in: String(characters[range.lowerBound..<index]),
                   activeAliases: aliases.activeNames(before: range.lowerBound)
               ) != nil {
                return index
            }
            state.trackDepth(character)
        }
        return nil
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
            } else if character == "#" {
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
}

enum YAMLNodeStart {
    static func containsOnlyProperties(in text: String) -> Bool {
        let characters = Array(text)
        guard var nodeIndex = contentIndex(in: characters, range: characters.indices) else { return false }
        var foundProperty = false
        while nodeIndex < characters.count, characters[nodeIndex] == "!" || characters[nodeIndex] == "&" {
            guard let propertyEnd = propertyEnd(in: characters, startingAt: nodeIndex) else { return false }
            foundProperty = true
            guard let next = contentIndex(in: characters, range: propertyEnd..<characters.count) else {
                return true
            }
            nodeIndex = next
        }
        return foundProperty && nodeIndex == characters.count
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
        if characters[start] == "!" {
            let next = start + 1
            if next == characters.count || characters[next].isWhitespace || characters[next] == "#" {
                return next
            }
        }
        if characters[start] == "!", start + 1 < characters.count, characters[start + 1] == "<" {
            guard let closing = characters[(start + 2)...].firstIndex(of: ">") else { return nil }
            return closing + 1
        }
        var index = start + 1
        while index < characters.count,
              !characters[index].isWhitespace,
              !"[]{} ,".contains(characters[index]) {
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
        if character == "\"" { quote = .double; return true }
        if character == "'" { quote = .single; return true }
        return false
    }

    mutating func trackDepth(_ character: Character) {
        switch character {
        case "{": curlyDepth += 1
        case "}": curlyDepth -= 1
        case "[": squareDepth += 1
        case "]": squareDepth -= 1
        default: break
        }
    }
}

private enum YAMLQuote: Equatable {
    case single
    case double
}
