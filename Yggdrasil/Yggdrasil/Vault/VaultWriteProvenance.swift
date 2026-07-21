import Foundation
import YggdrasilCore

enum VaultWriteProvenance {
    typealias TimestampProvider = @Sendable () throws -> String

    private enum InjectionError: LocalizedError {
        case unsafeFrontmatter

        var errorDescription: String? {
            "The note frontmatter could not be tagged without changing foreign YAML."
        }
    }

    static func applying(
        to text: String,
        relativePath: String,
        timestampProvider: TimestampProvider,
        failureLogger: @Sendable (String) -> Void
    ) -> String {
        do {
            return try injecting(into: text, writtenAt: timestampProvider())
        } catch {
            logFailure(error, relativePath: relativePath, failureLogger: failureLogger)
            return removingExistingProvenance(from: text)
        }
    }

    /// A failed tag attempt must not leave another writer attributed to the
    /// bytes Bifrost is about to replace. This fallback removes only a
    /// top-level `agent_provenance` value and otherwise preserves the
    /// requested text byte-for-byte.
    private static func removingExistingProvenance(from text: String) -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        guard text.hasPrefix("---\(newline)") else { return text }
        var lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              var closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return text
        }

        var index = 1
        while index < closingIndex {
            guard isAgentProvenanceEntry(lines[index]) else {
                index += 1
                continue
            }
            let endIndex = provenanceValueEnd(in: lines, after: index, before: closingIndex)
            lines.removeSubrange(index..<endIndex)
            closingIndex -= endIndex - index
        }
        return lines.joined(separator: newline)
    }

    private static func provenanceValueEnd(in lines: [String], after start: Int, before closing: Int) -> Int {
        guard let separator = mappingSeparator(in: lines[start]) else { return start + 1 }
        let remainder = lines[start][lines[start].index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        let isBlockValue = remainder.isEmpty || remainder.hasPrefix("|") || remainder.hasPrefix(">")
        guard isBlockValue else { return start + 1 }

        var end = start + 1
        while end < closing {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || line.first?.isWhitespace == true
                || (remainder.isEmpty && isSequenceEntry(trimmed)) {
                end += 1
                continue
            }
            break
        }
        return end
    }

    private static func injecting(into text: String, writtenAt: String) throws -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        let provenanceLines = [
            "agent_provenance:",
            "  author: bifrost-ios",
            "  written_at: \(writtenAt)",
            "  origin: direct-fs"
        ]

        guard text.hasPrefix("---\(newline)") else {
            return (["---"] + provenanceLines + ["---", "", text]).joined(separator: newline)
        }

        var lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw InjectionError.unsafeFrontmatter
        }

        let candidates = lines[1..<closingIndex].indices.filter { index in
            let line = lines[index]
            guard line.first?.isWhitespace != true else { return false }
            return line.contains("agent_provenance")
        }
        guard candidates.count <= 1 else { throw InjectionError.unsafeFrontmatter }

        if let startIndex = candidates.first {
            guard lines[startIndex].hasPrefix("agent_provenance:") else {
                throw InjectionError.unsafeFrontmatter
            }
            let remainder = lines[startIndex].dropFirst("agent_provenance:".count)
                .trimmingCharacters(in: .whitespaces)
            guard remainder.isEmpty else {
                throw InjectionError.unsafeFrontmatter
            }
            let endIndex = try replacementEnd(in: lines, after: startIndex, before: closingIndex)
            lines.replaceSubrange(startIndex..<endIndex, with: provenanceLines)
        } else {
            try insert(provenanceLines, into: &lines, before: closingIndex)
        }
        return lines.joined(separator: newline)
    }
    private static func replacementEnd(in lines: [String], after start: Int, before closing: Int) throws -> Int {
        var end = start + 1
        while end < closing {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                throw InjectionError.unsafeFrontmatter
            }
            if line.first?.isWhitespace == true {
                end += 1
                continue
            }
            guard !isSequenceEntry(trimmed) else {
                throw InjectionError.unsafeFrontmatter
            }
            break
        }
        return end
    }
    private static func isSequenceEntry(_ line: String) -> Bool {
        line.first == "-" && (line.count == 1 || line.dropFirst().first?.isWhitespace == true)
    }
    private static func insert(_ provenance: [String], into lines: inout [String], before closingIndex: Int) throws {
        guard acceptsBlockMappingInsertion(lines[1..<closingIndex]) else {
            throw InjectionError.unsafeFrontmatter
        }
        lines.insert(contentsOf: provenance, at: closingIndex)
    }
    private static func acceptsBlockMappingInsertion(_ lines: ArraySlice<String>) -> Bool {
        var sawMappingEntry = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                guard sawMappingEntry else { return false }
                continue
            }
            guard isPlainBlockMappingEntry(line) else { return false }
            sawMappingEntry = true
        }
        return true
    }
    private static func isPlainBlockMappingEntry(_ line: String) -> Bool {
        guard let separator = mappingSeparator(in: line) else { return false }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key.allSatisfy { character in
            character.isLetter || character.isNumber || character.isWhitespace || "_-.".contains(character)
        }
    }

    private static func isAgentProvenanceEntry(_ line: String) -> Bool {
        guard line.first?.isWhitespace != true,
              let separator = mappingSeparator(in: line) else { return false }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return key == "agent_provenance" || key == "\"agent_provenance\"" || key == "'agent_provenance'"
    }

    private static func mappingSeparator(in line: String) -> String.Index? {
        line.indices.first(where: { index in
            guard line[index] == ":", index != line.startIndex, !isSequenceEntry(line) else { return false }
            let next = line.index(after: index)
            return next == line.endIndex || line[next].isWhitespace
        })
    }

    @discardableResult
    static func apply(
        to document: inout FrontmatterDocument,
        relativePath: String,
        timestampProvider: TimestampProvider,
        failureLogger: @Sendable (String) -> Void
    ) -> Bool {
        do {
            document.applyBifrostProvenance(writtenAt: try timestampProvider())
            return true
        } catch {
            document.frontmatter["agent_provenance"] = nil
            logFailure(error, relativePath: relativePath, failureLogger: failureLogger)
            return false
        }
    }

    private static func logFailure(
        _ error: Error,
        relativePath: String,
        failureLogger: @Sendable (String) -> Void
    ) {
        let message = "Bifrost provenance tagging failed for \(relativePath); "
            + "writing note without provenance: \(error.localizedDescription)"
        failureLogger(message)
    }
}
