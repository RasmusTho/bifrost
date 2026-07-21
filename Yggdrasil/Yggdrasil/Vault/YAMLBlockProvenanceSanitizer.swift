import Foundation

struct YAMLBlockProvenanceSanitization {
    let lines: [String]
    let neutralized: Bool
}

enum YAMLBlockProvenanceSanitizer {
    static func neutralizingProvenance(
        in sourceLines: [String],
        before closing: Int,
        aliases: YAMLProvenanceAnchorBindings
    ) -> YAMLBlockProvenanceSanitization {
        var lines = sourceLines
        guard let rootIndent = blockMappingRootIndent(in: lines[1..<closing]) else {
            return YAMLBlockProvenanceSanitization(lines: lines, neutralized: false)
        }
        var neutralized = false
        var index = 1
        var frontmatterOffset = 0
        while index < closing {
            let originalLine = lines[index]
            let content = rootContent(of: lines[index], rootIndent: rootIndent)
            if let content,
               let keyRange = implicitOrInlineExplicitKeyRange(in: content),
               neutralizeInlineKey(
                   in: &lines,
                   at: index,
                   content: content,
                   keyRange: keyRange,
                   activeAliases: aliases.activeNames(before: frontmatterOffset)
               ) {
                neutralized = true
            } else if let content, isBareExplicitKeyIndicator(content),
                      let keyLine = multilineExplicitKeyLine(
                          in: lines,
                          after: index,
                          before: closing,
                          rootIndent: rootIndent
                      ) {
                let keyOffset = frontmatterOffset + lines[index..<keyLine].reduce(0) { $0 + $1.count + 1 }
                let match = YAMLProvenanceKey.replacementMatch(
                    in: lines[keyLine].trimmingCharacters(in: .whitespaces),
                    activeAliases: aliases.activeNames(before: keyOffset)
                )
                if let match {
                    let neutralName = YAMLProvenanceKey.availableNeutralName(in: lines.joined(separator: "\n"))
                    let indentation = lines[keyLine].prefix(while: { $0.isWhitespace }).count
                    lines[keyLine] = replacingKey(
                        in: lines[keyLine],
                        match: match,
                        offset: indentation,
                        with: neutralName
                    )
                    neutralized = true
                }
            }
            frontmatterOffset += originalLine.count + 1
            index += 1
        }
        return YAMLBlockProvenanceSanitization(lines: lines, neutralized: neutralized)
    }

    private static func neutralizeInlineKey(
        in lines: inout [String],
        at index: Int,
        content: String,
        keyRange: Range<String.Index>,
        activeAliases: Set<String>
    ) -> Bool {
        guard let match = YAMLProvenanceKey.replacementMatch(
            in: String(content[keyRange]),
            activeAliases: activeAliases
        ) else { return false }
        let keyOffset = content.distance(from: content.startIndex, to: keyRange.lowerBound)
        let rootIndent = lines[index].count - content.count
        let neutralName = YAMLProvenanceKey.availableNeutralName(in: lines.joined(separator: "\n"))
        lines[index] = replacingKey(
            in: lines[index],
            match: match,
            offset: rootIndent + keyOffset,
            with: neutralName
        )
        return true
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

    private static func rootContent(of line: String, rootIndent: String) -> String? {
        guard line.hasPrefix(rootIndent) else { return nil }
        let content = String(line.dropFirst(rootIndent.count))
        return content.first?.isWhitespace == true ? nil : content
    }

    private static func implicitOrInlineExplicitKeyRange(in content: String) -> Range<String.Index>? {
        if let separator = mappingSeparator(in: content) { return content.startIndex..<separator }
        guard isExplicitMappingEntry(content), !isBareExplicitKeyIndicator(content) else { return nil }
        return content.startIndex..<content.endIndex
    }

    private static func multilineExplicitKeyLine(
        in lines: [String],
        after indicator: Int,
        before closing: Int,
        rootIndent: String
    ) -> Int? {
        var candidate = indicator + 1
        while candidate < closing {
            let trimmed = lines[candidate].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                candidate += 1
                continue
            }
            if YAMLNodeStart.containsOnlyProperties(in: trimmed) {
                candidate += 1
                continue
            }
            guard lines[candidate].hasPrefix(rootIndent),
                  lines[candidate].dropFirst(rootIndent.count).first?.isWhitespace == true else {
                return nil
            }
            return candidate
        }
        return nil
    }

    private static func replacingKey(
        in line: String,
        match: YAMLProvenanceKeyMatch,
        offset: Int,
        with replacement: String
    ) -> String {
        var characters = Array(line)
        characters.replaceSubrange(
            (offset + match.range.lowerBound)..<(offset + match.range.upperBound),
            with: Array(replacement)
        )
        return String(characters)
    }

    private static func isBareExplicitKeyIndicator(_ content: String) -> Bool {
        let withoutComment = content.split(separator: "#", maxSplits: 1).first.map(String.init) ?? content
        return withoutComment.trimmingCharacters(in: .whitespaces) == "?"
    }

    private static func isExplicitMappingEntry(_ content: String) -> Bool {
        guard content.first == "?" else { return false }
        let next = content.index(after: content.startIndex)
        return next == content.endIndex || content[next].isWhitespace
    }

    private static func mappingSeparator(in line: String) -> String.Index? {
        var quote: Character?
        var escaping = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaping {
                    escaping = false
                } else if activeQuote == "\"", character == "\\" {
                    escaping = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "#" {
                let previous = index > line.startIndex ? line[line.index(before: index)] : nil
                if previous == nil || previous?.isWhitespace == true { return nil }
            }
            guard character == ":", index != line.startIndex else { continue }
            let next = line.index(after: index)
            if next == line.endIndex || line[next].isWhitespace { return index }
        }
        return nil
    }
}

enum YAMLProvenanceKey {
    static let activeName = "agent_provenance"
    static let neutralName = "former_writer_attribution"

    static func replacementMatch(in key: String, activeAliases: Set<String>) -> YAMLProvenanceKeyMatch? {
        let characters = Array(key)
        guard var nodeStart = contentIndex(in: characters, startingAt: 0) else { return nil }
        if isExplicitMappingEntry(at: nodeStart, in: characters) {
            guard let explicitNode = contentIndex(in: characters, startingAt: nodeStart + 1) else { return nil }
            nodeStart = explicitNode
        }
        guard let scalarStart = YAMLNodeStart.index(in: characters, startingAt: nodeStart) else { return nil }
        let literalForms = [
            (Array(activeName), 0),
            (Array("\"\(activeName)\""), 1),
            (Array("'\(activeName)'"), 1)
        ]
        for (form, replacementOffset) in literalForms {
            let end = scalarStart + form.count
            guard end <= characters.count, Array(characters[scalarStart..<end]) == form else { continue }
            if containsOnlyTrivia(characters[end...]) {
                let start = scalarStart + replacementOffset
                return YAMLProvenanceKeyMatch(range: start..<(start + activeName.count))
            }
        }
        guard characters[scalarStart] == "*" else { return nil }
        var end = scalarStart + 1
        while end < characters.count,
              !characters[end].isWhitespace,
              !"[]{} ,".contains(characters[end]) {
            end += 1
        }
        let name = String(characters[(scalarStart + 1)..<end])
        guard !name.isEmpty, activeAliases.contains(name), containsOnlyTrivia(characters[end...]) else { return nil }
        return YAMLProvenanceKeyMatch(range: scalarStart..<end)
    }

    static func availableNeutralName(in text: String) -> String {
        var candidate = neutralName
        var suffix = 2
        while text.contains(candidate) {
            candidate = "\(neutralName)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func isLiteralActiveNode(
        in characters: [Character],
        startingAt start: Int,
        isInFlow: Bool
    ) -> Bool {
        for form in [Array(activeName), Array("\"\(activeName)\""), Array("'\(activeName)'")] {
            let end = start + form.count
            guard end <= characters.count, Array(characters[start..<end]) == form else { continue }
            if isExactScalarTerminator(after: end, in: characters, isInFlow: isInFlow) { return true }
        }
        return false
    }

    private static func isExactScalarTerminator(
        after end: Int,
        in characters: [Character],
        isInFlow: Bool
    ) -> Bool {
        guard end < characters.count else { return true }
        var index = end
        if characters[index] == ":" {
            let next = index + 1
            return next == characters.count || characters[next].isWhitespace
                || (isInFlow && "[]{},".contains(characters[next]))
        }
        if isInFlow, "[],}".contains(characters[index]) { return true }
        guard characters[index].isWhitespace else { return false }
        while index < characters.count, characters[index].isWhitespace,
              characters[index] != "\n", characters[index] != "\r" {
            index += 1
        }
        guard index < characters.count else { return true }
        if characters[index] == "\n" || characters[index] == "\r" || characters[index] == "#" { return true }
        return isInFlow && "[],}".contains(characters[index])
    }

    private static func containsOnlyTrivia(_ suffix: ArraySlice<Character>) -> Bool {
        var inComment = false
        var previousWasWhitespace = false
        for character in suffix {
            if inComment {
                if character == "\n" || character == "\r" { inComment = false }
            } else if character == "#" {
                guard previousWasWhitespace else { return false }
                inComment = true
            } else if !character.isWhitespace {
                return false
            }
            previousWasWhitespace = character.isWhitespace
        }
        return true
    }

    private static func contentIndex(in characters: [Character], startingAt start: Int) -> Int? {
        var inComment = false
        for index in start..<characters.count {
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

    private static func isExplicitMappingEntry(at index: Int, in characters: [Character]) -> Bool {
        guard characters[index] == "?" else { return false }
        let next = index + 1
        return next == characters.count || characters[next].isWhitespace
    }
}

struct YAMLProvenanceKeyMatch {
    let range: Range<Int>
}
