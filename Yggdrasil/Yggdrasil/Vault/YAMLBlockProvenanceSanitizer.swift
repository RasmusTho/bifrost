import Foundation

struct YAMLBlockProvenanceSanitization {
    let lines: [String]
    let neutralized: Bool
}

private struct YAMLInlineKeyEntry {
    let index: Int
    let content: String
    let keyRange: Range<String.Index>
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
                   before: closing,
                   entry: YAMLInlineKeyEntry(index: index, content: content, keyRange: keyRange),
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
                if neutralizeMultilineKey(
                    in: &lines,
                    at: keyLine,
                    before: closing,
                    activeAliases: aliases.activeNames(before: keyOffset)
                ) {
                    neutralized = true
                }
            }
            frontmatterOffset += originalLine.count + 1
            index += 1
        }
        return YAMLBlockProvenanceSanitization(lines: lines, neutralized: neutralized)
    }

    private static func neutralizeMultilineKey(
        in lines: inout [String],
        at keyLine: Int,
        before closing: Int,
        activeAliases: Set<String>
    ) -> Bool {
        guard let match = YAMLProvenanceKey.replacementMatch(
            in: lines[keyLine].trimmingCharacters(in: .whitespaces),
            activeAliases: activeAliases
        ), let neutralName = YAMLProvenanceKey.availableNeutralName(
            in: lines[1..<closing].joined(separator: "\n")
        ) else { return false }
        let indentation = lines[keyLine].prefix(while: { $0.isWhitespace }).count
        lines[keyLine] = replacingKey(
            in: lines[keyLine],
            match: match,
            offset: indentation,
            with: neutralName
        )
        return true
    }

    private static func neutralizeInlineKey(
        in lines: inout [String],
        before closing: Int,
        entry: YAMLInlineKeyEntry,
        activeAliases: Set<String>
    ) -> Bool {
        guard let match = YAMLProvenanceKey.replacementMatch(
            in: String(entry.content[entry.keyRange]),
            activeAliases: activeAliases
        ) else { return false }
        let keyOffset = entry.content.distance(
            from: entry.content.startIndex,
            to: entry.keyRange.lowerBound
        )
        let rootIndent = lines[entry.index].count - entry.content.count
        guard let neutralName = YAMLProvenanceKey.availableNeutralName(
            in: lines[1..<closing].joined(separator: "\n")
        ) else { return false }
        lines[entry.index] = replacingKey(
            in: lines[entry.index],
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

    static func availableNeutralName(in text: String) -> String? {
        // A backslash can hide an equivalent double-quoted YAML key (for example,
        // "\u0066ormer_writer_attribution"). Without a full semantic key decoder,
        // collision freedom is unprovable, so preserve the requested bytes unchanged.
        guard !text.contains("\\") else { return nil }
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
        let forms = [
            (characters: Array(activeName), isPlain: true),
            (characters: Array("\"\(activeName)\""), isPlain: false),
            (characters: Array("'\(activeName)'"), isPlain: false)
        ]
        for form in forms {
            let end = start + form.characters.count
            guard end <= characters.count,
                  Array(characters[start..<end]) == form.characters else { continue }
            if isExactScalarTerminator(
                after: end,
                scalarStart: start,
                in: characters,
                isInFlow: isInFlow,
                isPlain: form.isPlain
            ) { return true }
        }
        return false
    }

    private static func isExactScalarTerminator(
        after end: Int,
        scalarStart: Int,
        in characters: [Character],
        isInFlow: Bool,
        isPlain: Bool
    ) -> Bool {
        guard end < characters.count else { return true }
        let index = end
        if characters[index] == ":" {
            let next = index + 1
            return next == characters.count || characters[next].isWhitespace
                || (isInFlow && "[]{},".contains(characters[next]))
        }
        if isInFlow, "[],}".contains(characters[index]) { return true }
        guard characters[index].isWhitespace else { return false }
        if isInFlow { return hasFlowScalarTerminator(after: index, in: characters) }
        return hasBlockScalarTerminator(
            after: index,
            scalarStart: scalarStart,
            in: characters,
            isPlain: isPlain
        )
    }

    private static func hasFlowScalarTerminator(
        after end: Int,
        in characters: [Character]
    ) -> Bool {
        var index = end
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            if index < characters.count, characters[index] == "#" {
                while index < characters.count,
                      characters[index] != "\n", characters[index] != "\r" { index += 1 }
                continue
            }
            break
        }
        return index == characters.count || "[],}".contains(characters[index])
    }

    private static func hasBlockScalarTerminator(
        after end: Int,
        scalarStart: Int,
        in characters: [Character],
        isPlain: Bool
    ) -> Bool {
        var index = end
        while index < characters.count,
              characters[index].isWhitespace,
              characters[index] != "\n", characters[index] != "\r" { index += 1 }
        if index < characters.count, characters[index] == "#" {
            while index < characters.count,
                  characters[index] != "\n", characters[index] != "\r" { index += 1 }
        }
        guard index < characters.count else { return true }
        guard characters[index] == "\n" || characters[index] == "\r" else { return false }
        return !isPlain || !hasIndentedContinuation(
            after: index,
            scalarStart: scalarStart,
            in: characters
        )
    }

    private static func hasIndentedContinuation(
        after lineBreak: Int,
        scalarStart: Int,
        in characters: [Character]
    ) -> Bool {
        let scalarIndent = lineIndent(containing: scalarStart, in: characters)
        var lineStart = lineBreak + 1
        if characters[lineBreak] == "\r", lineStart < characters.count,
           characters[lineStart] == "\n" { lineStart += 1 }
        while lineStart < characters.count {
            var content = lineStart
            while content < characters.count,
                  characters[content] == " " || characters[content] == "\t" { content += 1 }
            if content == characters.count { return false }
            if characters[content] == "\n" || characters[content] == "\r" || characters[content] == "#" {
                while content < characters.count,
                      characters[content] != "\n", characters[content] != "\r" { content += 1 }
                guard content < characters.count else { return false }
                lineStart = content + 1
                if characters[content] == "\r", lineStart < characters.count,
                   characters[lineStart] == "\n" { lineStart += 1 }
                continue
            }
            return content - lineStart > scalarIndent
        }
        return false
    }

    private static func lineIndent(containing index: Int, in characters: [Character]) -> Int {
        var start = index
        while start > 0, characters[start - 1] != "\n", characters[start - 1] != "\r" { start -= 1 }
        var content = start
        while content < characters.count,
              characters[content] == " " || characters[content] == "\t" { content += 1 }
        return content - start
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
