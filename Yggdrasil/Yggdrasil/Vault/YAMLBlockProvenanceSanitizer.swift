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
               let token = YAMLProvenanceKey.replacementToken(
                   in: String(content[keyRange]),
                   activeAliases: aliases.activeNames(before: frontmatterOffset)
               ) {
                lines[index] = rootIndent + replacingKeyToken(in: content, keyRange: keyRange, token: token)
                neutralized = true
            } else if let content, isBareExplicitKeyIndicator(content),
                      let keyLine = multilineExplicitKeyLine(
                          in: lines,
                          after: index,
                          before: closing,
                          rootIndent: rootIndent
                      ) {
                let keyOffset = frontmatterOffset + lines[index..<keyLine].reduce(0) { $0 + $1.count + 1 }
                let token = YAMLProvenanceKey.replacementToken(
                    in: lines[keyLine].trimmingCharacters(in: .whitespaces),
                    activeAliases: aliases.activeNames(before: keyOffset)
                )
                if let token {
                    lines[keyLine] = replacingKeyToken(in: lines[keyLine], token: token)
                    neutralized = true
                }
            }
            frontmatterOffset += originalLine.count + 1
            index += 1
        }
        return YAMLBlockProvenanceSanitization(lines: lines, neutralized: neutralized)
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

    private static func replacingKeyToken(
        in line: String,
        keyRange: Range<String.Index>? = nil,
        token: String
    ) -> String {
        let bounds = keyRange ?? line.startIndex..<line.endIndex
        guard let replacement = line.range(
            of: token,
            options: .backwards,
            range: bounds
        ) else { return line }
        return line.replacingCharacters(in: replacement, with: YAMLProvenanceKey.neutralName)
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

    static func replacementToken(in key: String, activeAliases: Set<String>) -> String? {
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
        for form in [activeName, "\"\(activeName)\"", "'\(activeName)'"] where candidate.hasPrefix(form) {
            let suffix = candidate.dropFirst(form.count)
            if containsOnlyTrivia(suffix) { return activeName }
        }
        guard candidate.first == "*" else { return nil }
        let token = String(candidate.prefix { !$0.isWhitespace && !"[]{} ,".contains($0) })
        let name = String(token.dropFirst())
        guard !name.isEmpty, activeAliases.contains(name), containsOnlyTrivia(candidate.dropFirst(token.count)) else {
            return nil
        }
        return token
    }

    static func isLiteralActiveNode(in characters: [Character], startingAt start: Int) -> Bool {
        for form in [Array(activeName), Array("\"\(activeName)\""), Array("'\(activeName)'")] {
            let end = start + form.count
            guard end <= characters.count, Array(characters[start..<end]) == form else { continue }
            if end == characters.count || characters[end].isWhitespace || "[]{} ,:".contains(characters[end]) {
                return true
            }
        }
        return false
    }

    private static func containsOnlyTrivia<S: StringProtocol>(_ suffix: S) -> Bool {
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

    private static func isExplicitMappingEntry(_ content: String) -> Bool {
        guard content.first == "?" else { return false }
        let next = content.index(after: content.startIndex)
        return next == content.endIndex || content[next].isWhitespace
    }
}
