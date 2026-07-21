import Foundation

struct YAMLProvenanceAnchorBindings {
    private let events: [YAMLProvenanceAnchorBinding]

    init(text: String) {
        let characters = Array(text)
        let blockScalarContent = Self.blockScalarContentIndices(in: characters)
        var bindings: [YAMLProvenanceAnchorBinding] = []
        var state = YAMLAnchorScanState()
        for index in characters.indices {
            if blockScalarContent.contains(index) { continue }
            let character = characters[index]
            if state.consume(character, at: index, in: characters) { continue }
            if character == "&", Self.isPropertyPosition(at: index, in: characters),
               let name = Self.anchorName(at: index, in: characters) {
                let isActive = Self.provenScalarNodeStart(after: index, in: characters).map {
                    YAMLProvenanceKey.isLiteralActiveNode(
                        in: characters,
                        startingAt: $0,
                        isInFlow: state.isInsideFlow
                    )
                } ?? false
                bindings.append(
                    YAMLProvenanceAnchorBinding(
                        name: name,
                        position: index,
                        resolvesToActiveName: isActive
                    )
                )
            }
            state.trackDepth(character)
        }
        events = bindings
    }

    func activeNames(before position: Int) -> Set<String> {
        var latest: [String: Bool] = [:]
        for event in events where event.position < position {
            latest[event.name] = event.resolvesToActiveName
        }
        return Set(latest.compactMap { $0.value ? $0.key : nil })
    }

    private static func isPropertyPosition(at index: Int, in characters: [Character]) -> Bool {
        let start = lineStart(before: index, in: characters)
        let trimmed = String(characters[start..<index]).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || YAMLNodeStart.containsOnlyProperties(in: trimmed) {
            return isStandaloneNodeLine(at: start, in: characters)
        }
        if trimmed == "-" || trimmed == "?" { return true }
        for separator in trimmed.indices.reversed() where trimmed[separator] == ":" {
            let after = trimmed.index(after: separator)
            let suffix = String(trimmed[after...]).trimmingCharacters(in: .whitespaces)
            if suffix.isEmpty || YAMLNodeStart.containsOnlyProperties(in: suffix) { return true }
        }
        return false
    }

    private static func isStandaloneNodeLine(at lineStart: Int, in characters: [Character]) -> Bool {
        guard lineStart > 0 else { return true }
        let currentIndent = indentation(at: lineStart, in: characters)
        var previousEnd = lineStart - 1
        while previousEnd > 0 {
            let previousStart = self.lineStart(before: previousEnd, in: characters)
            let line = String(characters[previousStart..<previousEnd])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                let previousIndent = indentation(at: previousStart, in: characters)
                if previousIndent == currentIndent, YAMLNodeStart.containsOnlyProperties(in: trimmed) {
                    return true
                }
                guard previousIndent < currentIndent else { return false }
                let withoutComment = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? line
                let indicator = withoutComment.trimmingCharacters(in: .whitespaces)
                return indicator == "?" || indicator == "-" || indicator.hasSuffix(":")
            }
            guard previousStart > 0 else { break }
            previousEnd = previousStart - 1
        }
        return false
    }

    private static func provenScalarNodeStart(after anchor: Int, in characters: [Character]) -> Int? {
        guard let nodeStart = YAMLNodeStart.index(in: characters, startingAt: anchor) else { return nil }
        let anchorLine = lineStart(before: anchor, in: characters)
        let nodeLine = lineStart(before: nodeStart, in: characters)
        guard anchorLine != nodeLine else { return nodeStart }
        let prefix = String(characters[anchorLine..<anchor]).trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty || YAMLNodeStart.containsOnlyProperties(in: prefix),
              indentation(at: anchorLine, in: characters) == indentation(at: nodeLine, in: characters) else {
            return nil
        }
        return nodeStart
    }

    private static func lineStart(before index: Int, in characters: [Character]) -> Int {
        guard index > 0,
              let newline = characters[..<index].lastIndex(where: { $0 == "\n" || $0 == "\r" }) else {
            return 0
        }
        return newline + 1
    }

    private static func indentation(at lineStart: Int, in characters: [Character]) -> Int {
        var end = lineStart
        while end < characters.count, characters[end].isWhitespace,
              characters[end] != "\n", characters[end] != "\r" {
            end += 1
        }
        return end - lineStart
    }

    private static func anchorName(at start: Int, in characters: [Character]) -> String? {
        var end = start + 1
        while end < characters.count,
              !characters[end].isWhitespace,
              !"[]{} ,:".contains(characters[end]) {
            end += 1
        }
        guard end > start + 1 else { return nil }
        return String(characters[(start + 1)..<end])
    }

    private static func blockScalarContentIndices(in characters: [Character]) -> Set<Int> {
        var ignored: Set<Int> = []
        var headerIndent: Int?
        var lineStart = 0
        while lineStart < characters.count {
            let lineEnd = characters[lineStart...].firstIndex(of: "\n") ?? characters.count
            let line = Array(characters[lineStart..<lineEnd])
            let indentation = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let isBlank = line.allSatisfy { $0.isWhitespace }
            if let base = headerIndent, isBlank || indentation > base {
                ignored.formUnion(lineStart..<lineEnd)
            } else {
                headerIndent = isBlockScalarHeader(line) ? indentation : nil
            }
            lineStart = lineEnd < characters.count ? lineEnd + 1 : characters.count
        }
        return ignored
    }

    private static func isBlockScalarHeader(_ line: [Character]) -> Bool {
        var state = YAMLAnchorScanState()
        for index in line.indices {
            let character = line[index]
            if state.consume(character, at: index, in: line) { continue }
            guard character == "|" || character == ">",
                  isPropertyPosition(at: index, in: line),
                  isBlockScalarSuffix(line[(index + 1)...]) else {
                continue
            }
            return true
        }
        return false
    }

    private static func isBlockScalarSuffix(_ suffix: ArraySlice<Character>) -> Bool {
        var previousWasWhitespace = false
        for character in suffix {
            if character == "#", previousWasWhitespace { return true }
            guard character.isWhitespace || character.isNumber || character == "+" || character == "-" else {
                return false
            }
            previousWasWhitespace = character.isWhitespace
        }
        return true
    }
}

private struct YAMLProvenanceAnchorBinding {
    let name: String
    let position: Int
    let resolvesToActiveName: Bool
}

private struct YAMLAnchorScanState {
    private var quote: YAMLAnchorQuote?
    private var inComment = false
    private var inVerbatimTag = false
    private var escapingDoubleQuote = false
    private var skipNextSingleQuote = false
    private var curlyDepth = 0
    private var squareDepth = 0

    var isInsideFlow: Bool { curlyDepth > 0 || squareDepth > 0 }

    mutating func consume(_ character: Character, at index: Int, in characters: [Character]) -> Bool {
        if consumeComment(character) { return true }
        if consumeVerbatimTag(character) { return true }
        if consumeSkippedSingleQuote() { return true }
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        if consumeQuoted(character, next: next) { return true }
        let previous = index > 0 ? characters[index - 1] : nil
        return consumeUnquoted(character, previous: previous, next: next)
    }

    private mutating func consumeComment(_ character: Character) -> Bool {
        guard inComment else { return false }
        if character == "\n" || character == "\r" { inComment = false }
        return true
    }

    private mutating func consumeVerbatimTag(_ character: Character) -> Bool {
        guard inVerbatimTag else { return false }
        if character == ">" { inVerbatimTag = false }
        return true
    }

    private mutating func consumeSkippedSingleQuote() -> Bool {
        guard skipNextSingleQuote else { return false }
        skipNextSingleQuote = false
        return true
    }

    private mutating func consumeQuoted(_ character: Character, next: Character?) -> Bool {
        switch quote {
        case .double:
            consumeDoubleQuoted(character)
            return true
        case .single:
            consumeSingleQuoted(character, next: next)
            return true
        case nil:
            return false
        }
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

    private mutating func consumeUnquoted(
        _ character: Character,
        previous: Character?,
        next: Character?
    ) -> Bool {
        if character == "#", previous == nil || previous?.isWhitespace == true {
            inComment = true
            return true
        }
        if character == "!", next == "<" {
            inVerbatimTag = true
            return true
        }
        if character == "\"" { quote = .double; return true }
        if character == "'" { quote = .single; return true }
        return false
    }

    mutating func trackDepth(_ character: Character) {
        switch character {
        case "{": curlyDepth += 1
        case "}": curlyDepth = max(0, curlyDepth - 1)
        case "[": squareDepth += 1
        case "]": squareDepth = max(0, squareDepth - 1)
        default: break
        }
    }
}

private enum YAMLAnchorQuote {
    case single
    case double
}
